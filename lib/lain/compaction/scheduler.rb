# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Compaction
    # WHEN a needed compaction actually runs, kept apart from {Need} (WHETHER
    # one is warranted) and {Context::Compact} (which PERFORMS one). While the
    # cache is warm and history is below a hard ceiling, DEFER -- rewriting
    # messages now would throw away a cache read that costs ~0.1x what the
    # rewrite costs. Crossing the hard cap, or approaching the context window,
    # FORCES a compaction even while warm, but that forced rewrite hits only
    # the message tier, so the cached tools+system prefix survives. A cold
    # cache runs the compaction for free: there is no warm prefix to protect.
    #
    # The decision depends on RUNTIME state (cache warmth, current usage) that
    # a pure `#render` must not see, so it is made HERE, in the loop, and its
    # only output into rendering is WHICH pipeline this turn uses.
    class Scheduler
      Decision = Data.define(:action, :tier)

      # The policy's outcome for one turn, its own value so the scheduler's
      # branches NAME a decision rather than nest three conditionals in one
      # method.
      #
      # Reopened rather than bodied inside `Data.define(...) do ... end`: a
      # constant declared in that block binds to the enclosing module, not the
      # Data class, so DEFER and its siblings must live here to be
      # `Decision::DEFER`.
      class Decision
        # @return [Boolean] whether this turn's render pipeline gains a Compact
        #   stage. A deferring decision renders exactly as the base strategy
        #   would -- the pass-through a non-compacting turn depends on.
        def compact? = action != :defer

        # The cache-state enum as read off THIS decision. Only called behind
        # {#compact?}, so only two outcomes need a mapping: an unforced warm
        # decision always defers and never asks, which is why `:warm` lives in
        # {Telemetry::Compaction}'s validated enum and not here.
        CACHE_STATES = { forced_warm: :forced, cold_free: :cold }.freeze
        def cache_state = CACHE_STATES.fetch(action)

        # Deferring wastes no cache; both forcing outcomes rewrite the message
        # tier. Stateless values, so the three outcomes are shared frozen
        # constants (Data freezes them) rather than per-turn allocations.
        DEFER = new(action: :defer, tier: nil)
        FORCED_WARM = new(action: :forced_warm, tier: :message)
        COLD_FREE = new(action: :cold_free, tier: :message)
      end

      # What a rewrite would cost, in the byte proxy: the messages as they are,
      # and as this scheduler's Compact leaves them. Taken ONCE, by {#measure},
      # and then read by everyone who asks a question about it.
      #
      # It exists because the two numbers had two independent owners: the floor
      # in {Compaction::Source} dumped both sides to decide whether the rewrite
      # was worth making, and the accounting below dumped both sides again to
      # journal them -- two Canonical passes over the whole history, twice per
      # compacting turn, for figures already known. One object is what lets the
      # decision and the record read the SAME measurement rather than two that
      # happen to agree.
      #
      # Its two members stay bare Integers: {Bench::PlanSweep::Driver} feeds
      # `before` straight back in as a `head_bytes:`/`history_size:` threshold.
      # It is only the PRICING boundary that must not see one, so {#dropped}
      # and {#remaining} are where the figures become {Lain::ProxyBytes}.
      Rewrite = Data.define(:before, :after) do
        # STRICT: a byte-NEUTRAL rewrite is declined too. It buys nothing and
        # still breaks the cache prefix, so `<=` would be a rewrite that costs
        # a full cache write to change nothing.
        def shrinks? = after < before

        # The clamp travels WITH the subtraction rather than being left behind
        # at the pricing site: a rewrite that grew the history dropped nothing,
        # and that is a fact about the measurement, not about the money.
        def dropped = ProxyBytes.new(count: [before - after, 0].max)

        def remaining = ProxyBytes.new(count: after)
      end

      # WHOSE rates this compaction's dollars may be quoted at, and whether they
      # may be quoted at all.
      #
      # `priced` is the model the scheduler was BUILT with -- what its PriceBook
      # lookups resolve. `ran_under` is the model in force on the turn being
      # journaled, which arrives per call because `/model` moves it mid-session
      # while this frozen object cannot follow.
      #
      # When they disagree, nothing is quoted. RE-pricing to `ran_under` would
      # be the fabrication rather than the fix: a live chat's book is the
      # degrading `CLI::Backend::COMPACTION_PRICES`, which answers ZERO for a
      # model it does not know, so "reprice" would silently invent a free
      # compaction. {PriceBook}'s own refusal to price an unlisted model is the
      # same doctrine, one tier up.
      Quote = Data.define(:priced, :ran_under) do
        def initialize(priced:, ran_under: nil)
          super(priced: priced&.to_s&.freeze, ran_under: ran_under&.to_s&.freeze)
        end

        # A quote is refused only when there WAS a price and the turn ran
        # somewhere else. A nil `priced` is the unpriced configuration, a
        # DIFFERENT state that must keep journaling differently; a nil
        # `ran_under` is "the caller did not say", and absence of information
        # cannot contradict a price.
        def switched? = !priced.nil? && !ran_under.nil? && priced != ran_under

        # A record carrying figures names the tier they are QUOTED IN; a
        # refused one names the tier that actually ran, the only fact about the
        # dollars still worth recording.
        def model = switched? ? ran_under : priced
      end
      private_constant :Quote

      # @param compact [Context::Compact] the combinator swapped into the render
      #   pipeline when a compaction is scheduled. Injected, never reached for,
      #   so the scheduler never performs the summarization itself and the
      #   pipeline it hands back stays pure.
      # @param hard_cap [Integer] the history ceiling that forces compaction even
      #   while warm, in whatever proxy unit the caller measures history in (the
      #   same byte/token proxy {Need} and {Context::Compact} use).
      # @param journal [#<<] where a compacting decision lands; the Null channel
      #   by default, so no caller guards `if journal`.
      # @param model [String, Symbol, nil] the tier this scheduler is PRICED
      #   for, through `price_book`. Fixed at construction, which is why
      #   `#pipeline` takes the model actually in force separately (see its
      #   `ran_under:` and {Quote}). nil is a legitimate configuration, not an
      #   error: those fields simply journal as zero.
      # @param price_book [Lain::PriceBook] how `model`'s usage becomes
      #   dollars; the bench default, like every other PriceBook consumer.
      def initialize(compact:, hard_cap:, journal: Channel::Null.instance, model: nil, price_book: PriceBook.default)
        @compact = compact
        @hard_cap = Integer(hard_cap)
        @journal = journal
        @model = model&.to_s
        @price_book = price_book
        freeze
      end

      # The pure policy. Defer while warm and below the cap (don't waste the
      # cache); force -- message-tier only -- on crossing the cap or approaching
      # the window even while warm; run for free once the cache is cold. A
      # compaction {Need} never warranted always defers, so a non-compacting
      # turn is untouched.
      #
      # @param need [Need::Result] the fired need-signals
      # @param cold [Boolean] the cache is confirmed cold
      # @param history_size [Integer] measured in {#initialize}'s hard_cap unit
      # @return [Decision]
      def evaluate(need:, cold:, history_size:)
        return Decision::DEFER unless need.needed?
        return Decision::COLD_FREE if cold
        return Decision::FORCED_WARM if forced?(need, history_size)

        Decision::DEFER
      end

      # The render pipeline for THIS turn, journaling a compacting decision's
      # full accounting as it commits to it. A deferring decision returns
      # `base` UNTOUCHED -- the same object -- so a non-compacting turn renders
      # byte-identically to a scheduler-free run and journals nothing.
      #
      # @param need [Need::Result] the fired need-signals, forwarded into
      #   {#evaluate}
      # @param cold [Boolean] the cache is confirmed cold, forwarded into
      #   {#evaluate}
      # @param history_size [Integer] measured in {#initialize}'s hard_cap unit,
      #   forwarded into {#evaluate}
      # @param base [#call, #requires] the strategy `#render` would use
      #   otherwise -- a Combinator, or a `->(workspace)` provider
      # @param rewrite [Rewrite, nil] what this turn's rewrite costs, from
      #   {#measure}, measured by whoever needed the numbers first rather than
      #   a second time here. nil is "the caller measured nothing", and it is
      #   measured for them INSIDE the compacting branch (see {#record}). Never
      #   captured into the returned pipeline -- see {COMPOSE}.
      # @param ran_under [String, Symbol, nil] the model in force on THIS turn.
      #   A per-call parameter and not a second ivar, because `/model` moves it
      #   mid-session while this object is frozen. It reaches only
      #   {#accounting}, never {COMPOSE}, so the shareability contract is
      #   untouched.
      # @param collapse_strategy [String] the name of the arm that collapses a
      #   span this run -- the bench's grouping key. Per-call for `ran_under:`'s
      #   reason, and what travels is the frozen String and never the strategy
      #   OBJECT, which may hold a live oracle and a mutable memo. This
      #   scheduler cannot answer it for itself: it is handed a PIPELINE, so
      #   the policy behind it is not a thing it can name. The default is the
      #   control arm rather than nil, because a caller naming none is running
      #   this scheduler's bare Compact, which IS the eager tier; nil is
      #   reserved for a record written before the field existed, and
      #   defaulting to it would make "control arm" and "unreadable" one value.
      # @return the base itself, or a provider riding Compact ahead of it
      def pipeline(need:, cold:, history_size:, base:, rewrite: nil, ran_under: nil,
                   collapse_strategy: Telemetry::Compaction::EAGER_CONTROL_ARM)
        decision = evaluate(need:, cold:, history_size:)
        record(decision, need, rewrite, ran_under, collapse_strategy) if decision.compact?
        pipeline_for(decision, base)
      end

      # What rewriting `messages` through this scheduler's Compact would cost.
      # PUBLIC, and the one place the measurement is taken: this object holds
      # the Compact, and a caller deciding whether the rewrite is worth making
      # needs the very numbers the accounting journals. Threading the answer
      # into {#pipeline} collapses two identical pairs of `Canonical.dump`s
      # into one.
      #
      # It runs `@compact` OFF the pipeline: the pipeline reruns it later,
      # deterministically, when `#render` calls it.
      #
      # @param messages [Array<Hash>] the history this turn would rewrite
      # @return [Rewrite]
      def measure(messages)
        Rewrite.new(before: Canonical.dump(messages).bytesize,
                    after: Canonical.dump(@compact.call(messages)).bytesize)
      end

      # Hoisted, because a `[].freeze` literal allocates a fresh Array per read,
      # and {#record}'s fallback measures one on every call that names none.
      NO_MESSAGES = [].freeze
      private_constant :NO_MESSAGES

      # Compact rides AHEAD of the base so the head is summarized before the
      # base's reminders inject and its cache marks land. What the injected
      # base MEANS is {Context.combinator_for}'s answer, asked rather than
      # re-derived.
      #
      # A module-scope lambda, NOT one built inside an instance method: a
      # Proc's binding captures its DEFINITION `self`, so a provider created in
      # a method would carry the Scheduler instance -- and its live IO-backed
      # Journal -- into the returned pipeline and fail `Ractor.shareable?`
      # ("Proc's self is not shareable") the moment a caller does
      # `Context.new(pipeline: scheduler.pipeline(...))`. Here `self` is the
      # Scheduler CLASS, and the shareable `compact`/`base` arrive as explicit
      # arguments.
      #
      # `make_shareable` both establishes the contract and enforces it loudly:
      # a caller who injects a Compact whose summarizer -- or a base provider
      # -- is not itself shareable gets an IsolationError HERE, not a silently
      # non-shareable Context downstream.
      COMPOSE = lambda do |compact, base|
        Ractor.make_shareable(->(workspace) { compact >> Context.combinator_for(base, workspace) })
      end
      private_constant :COMPOSE

      private

      def forced?(need, history_size)
        history_size >= @hard_cap || need.signals.include?(Need::ApproachingWindow::KIND)
      end

      def pipeline_for(decision, base)
        return base unless decision.compact?

        COMPOSE.call(@compact, base)
      end

      # The unmeasured caller's fallback lives HERE rather than in
      # {#pipeline}'s signature because a default argument is evaluated on
      # every call: `rewrite: measure(NO_MESSAGES)` there would run the Compact
      # and both dumps on the DEFERRING turns -- the steady state -- that
      # `if decision.compact?` keeps free.
      def record(decision, need, rewrite, ran_under, collapse_strategy)
        quote = Quote.new(priced: @model, ran_under:)
        @journal << accounting(decision, need, rewrite || measure(NO_MESSAGES), quote, collapse_strategy)
      end

      # `collapse_strategy:` is named EXPLICITLY and never left to the member's
      # own default: that default is nil, which {Telemetry::Compaction} reserves
      # for a record written before the field existed, so relying on it would
      # make "this journal predates the field" and "the caller forgot"
      # indistinguishable in the one stream a bench groups by arm.
      def accounting(decision, need, rewrite, quote, collapse_strategy)
        Telemetry::Compaction.new(
          trigger: need.signals, cache_state: decision.cache_state,
          bytes_before: rewrite.before, bytes_after: rewrite.after, model: quote.model,
          collapse_strategy:, **costs(quote, decision, rewrite)
        )
      end

      # Absent, never zero: `cost_spent` already zeroes legitimately on a
      # `:cold` compaction and both figures zero on an unpriced scheduler, so a
      # switched run reporting zero would be indistinguishable from one that
      # genuinely ran for free. The bytes and the trigger are still measured
      # and still journaled -- only the dollars are withheld.
      def costs(quote, decision, rewrite)
        return { cost_saved: nil, cost_spent: nil } if quote.switched?

        { cost_saved: cost_saved(rewrite.dropped), cost_spent: cost_spent(decision, rewrite.remaining) }
      end

      # What continuing to resend the dropped span every subsequent turn would
      # have cost, at the model's plain input rate.
      #
      # @param dropped [Lain::ProxyBytes] the span the rewrite drops. Not an
      #   Integer, because the {PriceBook} quotes per TOKEN while the
      #   measurement counts BYTES: `#to_tokens` is that crossing, stated once.
      def cost_saved(dropped)
        return BigDecimal(0) if @model.nil?

        @price_book.cost(@model, Usage.new(input_tokens: dropped.to_tokens))
      end

      # A `:forced` compaction pays a cache_creation rewrite of the new head;
      # a `:cold` one is free -- there was no warm prefix left to protect.
      #
      # @param decision [Decision] this turn's outcome, read for its cache state
      # @param remaining [Lain::ProxyBytes] the shorter prefix the rewrite
      #   leaves, crossed into tokens exactly as {#cost_saved}'s operand is.
      def cost_spent(decision, remaining)
        return BigDecimal(0) if @model.nil? || decision.cache_state == :cold

        @price_book.cost(@model, Usage.new(cache_creation_input_tokens: remaining.to_tokens))
      end
    end
  end
end
