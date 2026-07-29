# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Compaction
    # WHEN a needed compaction actually runs, kept apart from {Need} (WHETHER
    # one is warranted) and {Context::Compact} (which PERFORMS one). The policy
    # that separates need from timing: while the cache is warm and history is
    # below a hard ceiling, DEFER -- rewriting messages now would throw away a
    # cache read that costs ~0.1x what the rewrite costs. Crossing the hard cap,
    # or approaching the context window, FORCES a compaction even while warm --
    # but that forced rewrite hits only the message tier, so the cached
    # tools+system prefix survives (see cache-aware-compaction.md's tiered
    # invalidation). A cold cache runs the compaction for free: there is no warm
    # prefix left to protect.
    #
    # It never mutates {Context} and never makes {Context::Compact} impure. The
    # decision depends on RUNTIME state (cache warmth, current usage) that a pure
    # `#render` must not see, so it is made HERE, in the loop, and its only
    # output into rendering is WHICH pipeline this turn uses -- Compact swapped
    # in via T21's injected-pipeline seam, or the base strategy untouched.
    class Scheduler
      # The policy's outcome for one turn, extracted as its own value so the
      # scheduler's branches NAME a decision rather than nest three conditionals
      # in one method (CLAUDE.md: a tripped Metrics/* cop here would be pointing
      # at this missing collaborator, not licensing a raised limit).
      Decision = Data.define(:action, :tier)

      # Reopened rather than bodied inside `Data.define(...) do ... end`: a
      # constant declared in that block binds to the enclosing module, not the
      # Data class (a known trap -- see Request::SYSTEM_PREFIX), so DEFER and its
      # siblings must live here to be `Decision::DEFER`.
      class Decision
        # @return [Boolean] whether this turn's render pipeline gains a Compact
        #   stage. A deferring decision renders exactly as the base strategy
        #   would -- the pass-through a non-compacting turn depends on.
        def compact? = action != :defer

        # T20/CAC-6's cache-state enum (`:warm`/`:cold`/`:forced`) as read off
        # THIS decision. Only called behind {#compact?} (see every call
        # site), so only the two outcomes below need a mapping -- `:warm`
        # lives in {Telemetry::Compaction}'s validated enum for schema
        # completeness, not here, since an unforced warm decision always
        # defers and never asks.
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
      # It exists because the two numbers had two independent owners. The floor
      # in {Compaction::Source} decides "is this rewrite worth making" by
      # dumping both sides; the accounting below journals "before" and "after"
      # by dumping both sides again -- the same two Canonical passes over the
      # whole history, twice per compacting turn, for figures that were already
      # known. A pair that always travels together and is always derived at
      # once is an object (CLAUDE.md), and making it one is what lets the
      # decision and the record read the SAME measurement rather than two that
      # happen to agree.
      Rewrite = Data.define(:before, :after) do
        # STRICT: a byte-NEUTRAL rewrite is declined too. It buys nothing and
        # still breaks the cache prefix, so `<=` would be a rewrite that costs
        # a full cache write to change nothing.
        def shrinks? = after < before
      end

      # WHOSE rates this compaction's dollars may be quoted at, and whether they
      # may be quoted at all.
      #
      # `priced` is the model the scheduler was BUILT with -- what its PriceBook
      # lookups resolve. `ran_under` is the model in force on the turn being
      # journaled, which arrives per call because `/model` moves it mid-session
      # (model_switch.rb:20-22) while this frozen object cannot follow.
      #
      # When they disagree, nothing is quoted. RE-pricing to `ran_under` would
      # be the fabrication rather than the fix: a live chat's book is the
      # degrading `CLI::Backend::COMPACTION_PRICES`, which answers ZERO for a
      # model it does not know, so "reprice" would silently invent a free
      # compaction. {PriceBook}'s own refusal to price an unlisted model
      # (price_book.rb:112) is the doctrine, one tier up.
      Quote = Data.define(:priced, :ran_under) do
        def initialize(priced:, ran_under: nil)
          super(priced: priced&.to_s&.freeze, ran_under: ran_under&.to_s&.freeze)
        end

        # A quote is refused only when there WAS a price and the turn ran
        # somewhere else. A nil `priced` is the unpriced configuration -- zeros
        # beside a nil model, which {Telemetry::Compaction}'s header documents
        # as legitimate and which is a DIFFERENT state that must keep journaling
        # differently. A nil `ran_under` is "the caller did not say": absence of
        # information cannot contradict a price.
        def switched? = !priced.nil? && !ran_under.nil? && priced != ran_under

        # The tier the record names. A record carrying figures names the tier
        # they are QUOTED IN (identical to the one that ran, or the caller named
        # none); a refused one names the tier that actually ran, the only fact
        # about the dollars still worth recording.
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
      #   for, through `price_book`, for T20/CAC-6's `cost_saved`/`cost_spent`.
      #   Fixed here at construction, which is why `#pipeline` takes the model
      #   actually in force separately (see its `ran_under:` and {Quote}). nil
      #   is a legitimate configuration -- see {Telemetry::Compaction}'s header
      #   -- not an error: those fields simply journal as zero.
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
      # @param need [Need::Result] the fired need-signals (T16)
      # @param cold [Boolean] the cache is confirmed cold (T17)
      # @param history_size [Integer] measured in {#initialize}'s hard_cap unit
      # @return [Decision]
      def evaluate(need:, cold:, history_size:)
        return Decision::DEFER unless need.needed?
        return Decision::COLD_FREE if cold
        return Decision::FORCED_WARM if forced?(need, history_size)

        Decision::DEFER
      end

      # The render pipeline for THIS turn, journaling a compacting decision's
      # FULL accounting (T20/CAC-6: trigger, cache-state, tokens before/after,
      # cost saved vs. spent) as it commits to it. The choice is made HERE --
      # off runtime signals a pure `#render` must never see -- which is
      # exactly what keeps `#render` the pure function prompt-cache stability
      # depends on. A deferring decision returns `base` UNTOUCHED (the same
      # object), so a non-compacting turn renders byte-identically to a
      # scheduler-free run and journals nothing.
      #
      # @param base [#call, #requires] the strategy `#render` would use
      #   otherwise -- a Combinator, or a `->(workspace)` provider (T21's
      #   injected-pipeline shape)
      # @param rewrite [Rewrite, nil] what this turn's rewrite costs, from
      #   {#measure} -- T20/CAC-6's before/after accounting, measured by
      #   whoever needed the numbers first rather than a second time here. nil
      #   is "the caller measured nothing", and it is measured for them INSIDE
      #   the compacting branch (see {#record}). Never captured into the
      #   returned pipeline (see {COMPOSE}'s shareability comment -- nothing
      #   this method closes over may ride along).
      # @param ran_under [String, Symbol, nil] the model in force on THIS turn.
      #   A per-call parameter and not a second ivar: `/model` moves it
      #   mid-session while this object is frozen, and the model in force is a
      #   fact about the turn rather than about the scheduler's configuration.
      #   It reaches only {#accounting} -- never {COMPOSE} -- so nothing the
      #   composed pipeline closes over changes and the T21/T19 shareability
      #   contract is untouched. nil means "the caller did not say", which
      #   journals exactly as it did before {Quote} existed.
      # @return the base itself, or a provider riding Compact ahead of it
      def pipeline(need:, cold:, history_size:, base:, rewrite: nil, ran_under: nil)
        decision = evaluate(need:, cold:, history_size:)
        record(decision, need, rewrite, ran_under) if decision.compact?
        pipeline_for(decision, base)
      end

      # What rewriting `messages` through this scheduler's Compact would cost,
      # as a {Rewrite}. PUBLIC, and the one place the measurement is taken:
      # this object holds the Compact, so it is the only one that can apply it,
      # and a caller deciding whether the rewrite is worth making
      # ({Compaction::Source}'s floor) needs the very numbers the accounting
      # journals. Asking here and threading the answer into {#pipeline} is what
      # collapses two identical pairs of `Canonical.dump`s into one.
      #
      # It runs `@compact` OFF the pipeline, as the accounting always did: the
      # pipeline reruns it later, deterministically, when `#render` calls it.
      #
      # @param messages [Array<Hash>] the history this turn would rewrite
      # @return [Rewrite]
      def measure(messages)
        Rewrite.new(before: Canonical.dump(messages).bytesize,
                    after: Canonical.dump(@compact.call(messages)).bytesize)
      end

      # Compact rides AHEAD of the base so the head is summarized before the
      # base's reminders inject and its cache marks land. What the injected base
      # MEANS is {Context.combinator_for}'s answer, asked rather than re-derived:
      # this used to carry its own copy of that duck-check under a comment asking
      # the next reader to keep the two in sync by hand.
      #
      # It is a module-scope lambda, NOT one built inside an instance method, on
      # purpose: a Proc's binding captures its DEFINITION `self`, so a provider
      # created in a method would carry the Scheduler instance -- and its live
      # IO-backed Journal -- into the returned pipeline, making it fail
      # `Ractor.shareable?` (IsolationError: "Proc's self is not shareable")
      # the moment a caller does `Context.new(pipeline: scheduler.pipeline(...))`.
      # Here `self` is the Scheduler CLASS (shareable), and the shareable
      # `compact`/`base` arrive as explicit arguments, so the composed pipeline
      # stays shareable when both of them are (the T21PipelineProviders::DEFAULT
      # idiom in context_spec).
      # `make_shareable` both establishes the contract and enforces it loudly:
      # a caller who injects a Compact whose summarizer -- or a base provider --
      # is not itself shareable gets an IsolationError HERE, not a silently
      # non-shareable Context downstream.
      # Hoisted, because a `[].freeze` literal allocates a fresh Array per read,
      # and {#pipeline}'s default measures one on every call that names none.
      NO_MESSAGES = [].freeze
      private_constant :NO_MESSAGES

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

      # The unmeasured caller's fallback, and the reason it is HERE rather than
      # in {#pipeline}'s signature: a default argument is evaluated on every
      # call, so `rewrite: measure(NO_MESSAGES)` would run the Compact and both
      # dumps on the DEFERRING turns -- the steady state -- that
      # `if decision.compact?` has always kept free. Same figures as ever for a
      # caller that names nothing; no work at all for one that defers.
      def record(decision, need, rewrite, ran_under)
        quote = Quote.new(priced: @model, ran_under:)
        @journal << accounting(decision, need, rewrite || measure(NO_MESSAGES), quote)
      end

      # The measurement, journaled -- taken by {#measure}, not retaken here.
      def accounting(decision, need, rewrite, quote)
        Telemetry::Compaction.new(
          trigger: need.signals, cache_state: decision.cache_state,
          tokens_before: rewrite.before, tokens_after: rewrite.after, model: quote.model,
          **costs(quote, decision, rewrite.before, rewrite.after)
        )
      end

      # Absent, never zero: `cost_spent` already zeroes legitimately on a
      # `:cold` compaction and both figures zero on an unpriced scheduler, so a
      # switched run reporting zero would be indistinguishable from one that
      # genuinely ran for free. The tokens and the trigger are still measured
      # and still journaled -- only the dollars are withheld.
      def costs(quote, decision, before, after)
        return { cost_saved: nil, cost_spent: nil } if quote.switched?

        { cost_saved: cost_saved(before, after), cost_spent: cost_spent(decision, after) }
      end

      # What continuing to resend the dropped tokens every subsequent turn
      # would have cost, at the model's plain input rate.
      def cost_saved(before, after)
        return BigDecimal(0) if @model.nil?

        @price_book.cost(@model, Usage.new(input_tokens: [before - after, 0].max))
      end

      # A `:forced` compaction pays a cache_creation rewrite of the new head;
      # a `:cold` one is free -- there was no warm prefix left to protect
      # (see this class's header).
      def cost_spent(decision, after)
        return BigDecimal(0) if @model.nil? || decision.cache_state == :cold

        @price_book.cost(@model, Usage.new(cache_creation_input_tokens: after))
      end
    end
  end
end
