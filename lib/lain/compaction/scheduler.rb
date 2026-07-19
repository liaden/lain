# frozen_string_literal: true

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
      # One journaled record: a needed compaction ran NOW, why, and which cache
      # tier its rewrite touched. `forced_warm` + `message` is the AC's
      # "forced-warm, message-tier only" -- while warm, only the message tier is
      # rewritten so the cached prefix is spared.
      CompactionScheduled = Data.define(:reason, :tier) do
        include Telemetry::Journalable
      end

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

        # The journal record for a compacting decision. Guarded by {#compact?}
        # at every call site, so a deferring decision's nil tier is never
        # serialized.
        def record = CompactionScheduled.new(reason: action, tier:)

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
      def initialize(compact:, hard_cap:, journal: Channel::Null.instance)
        @compact = compact
        @hard_cap = Integer(hard_cap)
        @journal = journal
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

      # The render pipeline for THIS turn, journaling a compacting decision as it
      # commits to it. The choice is made HERE -- off runtime signals a pure
      # `#render` must never see -- which is exactly what keeps `#render` the
      # pure function prompt-cache stability depends on. A deferring decision
      # returns `base` UNTOUCHED (the same object), so a non-compacting turn
      # renders byte-identically to a scheduler-free run.
      #
      # @param base [#call, #requires] the strategy `#render` would use
      #   otherwise -- a Combinator, or a `->(workspace)` provider (T21's
      #   injected-pipeline shape)
      # @return the base itself, or a provider riding Compact ahead of it
      def pipeline(need:, cold:, history_size:, base:)
        decision = evaluate(need:, cold:, history_size:)
        @journal << decision.record if decision.compact?
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
    end
  end
end
