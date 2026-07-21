# frozen_string_literal: true

module Lain
  module Plan
    # PC-3's driver: the bench-style loop that runs a {Plan::Document} chunk by
    # chunk behind ONE continuation contract, so a study can swap the execution
    # SHAPE ({ForkPerStep} vs {LinearRewrite}) without touching plan content. The
    # same built-for-the-bench posture as {Bench::Arm} and {Compaction::Scheduler}:
    # Lain owns the loop because the loop is the object of study, and live
    # +agent.rb+ wiring is a deliberate later follow-up, not this driver.
    #
    # The Runner owns per-turn {Context} construction -- it builds
    # +Context.new(pipeline: continuation.pipeline)+ for every step, so a seam's
    # pipeline swap takes effect on the very next render -- and it owns seam
    # detection off the document's {Document#chunks}. Everything shape-specific
    # is behind the injected +policy+'s +at_seam+; the loop itself is identical
    # for both shapes.
    #
    # Each chunk runs on a FORK of the current mainline (+continuation.timeline+):
    # for {LinearRewrite} that fork simply continues the one linear chain, for
    # {ForkPerStep} it is a branch the seam abandons. Every step closes into a
    # deterministic {Closure} (recorded in the Store and journaled), and the
    # chunk's final closure drives the seam.
    class Runner
      # A policy that carries its own mainline root (a {ForkPerStep}) was
      # constructed from a DIFFERENT Timeline than the one `#run` starts from --
      # so its forks would descend from `#run`'s root while the policy grew a
      # parallel mainline off its own, silently, and every continuation head the
      # policy returned would be unreachable in the run's Store. Caught loudly at
      # run start rather than surfacing later as a {Store::MissingObject} or a
      # divergent chain.
      class MainlineMismatch < Error; end

      # The agent's outcome for one step: the advanced timeline, the step's
      # {Grader::Grade}, and the {Workspace::Snapshot} event in force (or nil).
      # A convenience shape an injected +agent_step+ may return; the Runner only
      # needs the three readers.
      Outcome = Data.define(:timeline, :grade, :snapshot) do
        def initialize(timeline:, grade:, snapshot: nil)
          super
        end
      end

      # What one run produced. Not a value-with-shareability contract (it carries
      # Timelines, which never are -- see {Continuation}): a plain record the
      # bench reads.
      #
      # * +closures+ -- one {Closure} per step, in order (AC: "closure records
      #   for every step").
      # * +continuations+ -- the mainline as a chain: the initial continuation
      #   plus the one adopted after each seam. Rendering these is the mainline
      #   prefix-digest chain the churn proof compares.
      # * +forks+ -- the per-chunk fork as the chunk left it, so a caller can
      #   assert each fork inherited the mainline prefix.
      Report = Data.define(:closures, :continuations, :forks)

      # @param document [Plan::Document] the plan; never mutated, so its bytes
      #   are identical before every run regardless of shape
      # @param policy [#at_seam] the execution shape ({ForkPerStep}/{LinearRewrite})
      # @param agent_step [#call] answers
      #   +call(step:, timeline:, context:, workspace:) -> #timeline, #grade, #snapshot+;
      #   it renders through the Runner-built +context+, drives the provider, and
      #   commits the step's turns
      # @param model [String, Symbol] the Context model
      # @param max_tokens [Integer] the Context max_tokens
      # @param system [String, Array, nil] the Context system prompt
      # @param journal [#<<] where each closure's {Telemetry::ClosureRecord} lands
      def initialize(document:, policy:, agent_step:, model:, max_tokens:, system: nil,
                     journal: Channel::Null.instance)
        @document = document
        @policy = policy
        @agent_step = agent_step
        @model = model
        @max_tokens = max_tokens
        @system = system
        @journal = journal
      end

      # Execute the whole plan from +timeline+ (the store-backed mainline root)
      # rendering through +pipeline+, under the injected shape.
      #
      # @param timeline [Timeline] the mainline root; a {ForkPerStep} policy is
      #   constructed from this SAME Timeline so the two never drift
      # @param pipeline the initial render strategy (Combinator or provider)
      # @param workspace [Workspace] sent, not stored, into each render
      # @return [Report]
      def run(timeline:, pipeline:, workspace: Workspace.empty)
        ensure_policy_root!(timeline)
        store = timeline.store
        seed = Continuation.new(head_digest: timeline.head_digest, pipeline:)
        run_from(seed, store, workspace)
      end

      private

      # A mainline-bearing policy MUST have been seeded from this exact root
      # (same Store, same head), or the two would drift. A policy that carries no
      # mainline ({LinearRewrite}) has nothing to reconcile and is left alone.
      def ensure_policy_root!(timeline)
        return unless @policy.respond_to?(:mainline)

        root = @policy.mainline
        return if root.store.equal?(timeline.store) && root.head_digest == timeline.head_digest

        raise MainlineMismatch,
              "policy mainline root #{root.head_digest.inspect} does not match run root " \
              "#{timeline.head_digest.inspect} (they must be the same head over the same Store)"
      end

      def run_from(seed, store, workspace)
        closures = []
        continuations = [seed]
        forks = []
        # The fold threads the CURRENT continuation through the chunks; each
        # seam's next continuation is what the following chunk forks from. We
        # keep the arrays (not the fold's final value) -- continuations.last IS
        # that final value, already captured below.
        @document.chunks.inject(seed) do |current, chunk|
          fork = run_chunk(chunk, current, store, workspace, closures)
          forks << fork
          next_state = Continuation.new(head_digest: fork.head_digest, pipeline: current.pipeline)
          @policy.at_seam(state: next_state, closure: closures.last).tap { |after| continuations << after }
        end
        Report.new(closures:, continuations:, forks:)
      end

      # Run every step of one chunk on a fork of the current mainline, appending
      # each step's Closure to +closures+. Returns the fork as the chunk left it.
      def run_chunk(chunk, continuation, store, workspace, closures)
        chunk.inject(continuation.timeline(store)) do |fork, step|
          before = fork.length
          outcome = step_outcome(step, fork, continuation.pipeline, workspace)
          closures << close(step, outcome, before, store)
          outcome.timeline
        end
      end

      def step_outcome(step, fork, pipeline, workspace)
        context = Context.new(model: @model, max_tokens: @max_tokens, system: @system, pipeline:)
        @agent_step.call(step:, timeline: fork, context:, workspace:)
      end

      # Fold the step's chunk of turns into a deterministic Closure and record it
      # (Store + journal). The step is advanced to its OUTCOME status first, so
      # the record's status and its purge-failed-keep-error branch reflect the
      # grade rather than the not-yet-run plan status.
      def close(step, outcome, before, store)
        closed = step.with_status(outcome.grade.pass? ? "done" : "failed")
        closure = Closure.build(step: closed, timeline: outcome.timeline,
                                chunk_range: (before...outcome.timeline.length),
                                grade: outcome.grade, snapshot: outcome.snapshot)
        closure.record(store:, plan_digest: @document.digest, journal: @journal)
        closure
      end
    end
  end
end
