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

      # @param compact [Context::Compact] the combinator swapped into the render
      #   pipeline when a compaction is scheduled. Injected, never reached for,
      #   so the scheduler never performs the summarization itself and the
      #   pipeline it hands back stays pure.
      # @param hard_cap [Integer] the history ceiling that forces compaction even
      #   while warm, in whatever proxy unit the caller measures history in (the
      #   same byte/token proxy {Need} and {Context::Compact} use).
      # @param journal [#<<] where a compacting decision lands; the Null channel
      #   by default, so no caller guards `if journal`.
      # @param model [String, Symbol, nil] the tier this scheduler is running
      #   under, priced through `price_book` for T20/CAC-6's `cost_saved`/
      #   `cost_spent`. nil is a legitimate configuration -- see
      #   {Telemetry::Compaction}'s header -- not an error: those fields
      #   simply journal as zero.
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
      # @param messages [Array<Hash>] the candidate-for-drop head, the same
      #   messages {Need#check} was run against -- used ONLY here, to measure
      #   T20/CAC-6's before/after accounting; never captured into the
      #   returned pipeline (see {COMPOSE}'s shareability comment -- nothing
      #   this method closes over may ride along).
      # @return the base itself, or a provider riding Compact ahead of it
      def pipeline(need:, cold:, history_size:, base:, messages: [])
        decision = evaluate(need:, cold:, history_size:)
        @journal << accounting(decision, need, messages) if decision.compact?
        pipeline_for(decision, base)
      end

      # Compact rides AHEAD of the base so the head is summarized before the
      # base's reminders inject and its cache marks land. The duck-check mirrors
      # Context#pipeline_for EXACTLY (a Combinator used as-is, else a
      # `->(workspace)` provider called per render) -- keep the two in sync.
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
      COMPOSE = lambda do |compact, base|
        Ractor.make_shareable(
          ->(workspace) { compact >> (base.respond_to?(:requires) ? base : base.call(workspace)) }
        )
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

      # Runs `@compact` HERE, off the pipeline, purely to measure the
      # before/after byte-proxy T20/CAC-6 wants journaled -- the returned
      # pipeline reruns it later, deterministically, when `#render` actually
      # calls it (see {COMPOSE}'s shareability comment for why this method's
      # `messages` cannot ride along inside that closure instead).
      def accounting(decision, need, messages)
        before = Canonical.dump(messages).bytesize
        after = Canonical.dump(@compact.call(messages)).bytesize

        Telemetry::Compaction.new(
          trigger: need.signals, cache_state: decision.cache_state,
          tokens_before: before, tokens_after: after,
          cost_saved: cost_saved(before, after), cost_spent: cost_spent(decision, after)
        )
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
