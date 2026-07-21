# frozen_string_literal: true

module Lain
  module Bench
    class PlanSweep
      # Runs ONE (arm, run) cell and folds it to the three measured numbers:
      # grader score, a context-byte token proxy, and cache-writes. Everything is
      # real except the model's words: the plan-shaped arms run through the actual
      # {Plan::Runner} under the actual {Plan::ForkPerStep}/{Plan::LinearRewrite}
      # policies, and every arm's tokens/cache-writes come off REAL renders, so
      # the shape difference under study is genuine while the eval spends nothing
      # and repeats byte-identically.
      #
      # == The two measurements, and their honest fidelity
      #
      # TOKENS is a byte proxy -- the canonical byte length of what each turn
      # would resend -- not a live tokenizer. It is the same proxy {Context::Compact}
      # and {Compaction::Need} threshold on, and it is the number the study is
      # about: how much CONTEXT each shape resends per turn. It is measured off the
      # real render, so fork-per-step (small mainline, chunk-local forks) and
      # linear-rewrite (one chain, summarized at each seam) genuinely diverge.
      #
      # CACHE-WRITES is derived from {Bench::Rewrites} over the mainline's
      # prefix-digest chain, NOT from Usage -- because {Provider::Mock} never
      # populates cache fields (the PC-6 escalation trigger). A cache-write is a
      # prefix REWRITE: the persistent cached prefix invalidated and re-created.
      # The plan-shaped arms project rewrites over the mainline CONTINUATION chain
      # (the append-only proof P3 pins: fork rewrites zero, linear one per seam);
      # the reactive arm projects over its single linear timeline's per-turn chain
      # (its timeline IS the mainline). Same meaning -- rewrites of the persistent
      # prefix -- sampled where each shape's mainline actually advances.
      #
      # WALL-CLOCK is deliberately never measured: a mock replay has no real
      # parallelism to time, so the {Report} marks it ABSENT rather than fabricate
      # a number (the {ArmSweep} precedent).
      class Driver
        # The production-default cache-marking pipeline every arm renders through,
        # so the prefix-digest chains reflect a real render's cache marks. A
        # module-scope shareable lambda (self == the class): a Proc built inside a
        # method would capture the Driver instance and fail Ractor.make_shareable
        # the moment a Context stored it.
        BASE_PIPELINE = Ractor.make_shareable(->(_workspace) { Context::CacheBreakpoints.new })

        # The reactive baseline's compaction knobs. One byte proxy governs all
        # three so {Compaction::Need}'s token-threshold, the {Compaction::Scheduler}'s
        # hard cap, and {Context::Compact}'s own threshold agree: once the
        # CANDIDATE-FOR-DROP head crosses it, the need fires, the warm decision is
        # FORCED, and Compact actually elides -- the honest cache-aware-compaction
        # pipeline the card names as the baseline. The three measure the SAME
        # bytes (the candidate head, {Scheduler#pipeline}'s documented `messages:`
        # contract) so the scheduler never journals a compaction Compact no-ops.
        # Sized off the fixture (every run's candidate head crosses it by the
        # third step) so the baseline genuinely compacts partway through each run.
        REACTIVE_THRESHOLD = 250
        private_constant :REACTIVE_THRESHOLD

        # Trailing messages Compact keeps verbatim; the candidate-for-drop head is
        # everything before them.
        REACTIVE_KEEP_LAST = 1
        private_constant :REACTIVE_KEEP_LAST

        # A fixed, deterministic stand-in for the elided head. Real enough for the
        # baseline (the reactive scheduler's job is WHEN to compact, not how well
        # it summarizes), and fixed so a rerun reproduces it byte-for-byte.
        REACTIVE_SUMMARY = "[reactive compaction: earlier turns summarized to protect the warm prefix]"
        private_constant :REACTIVE_SUMMARY

        # @param fixture [Fixture] the loaded plan + scripted runs + gold
        def initialize(fixture:, model: "plan-sweep", max_tokens: 1024)
          @fixture = fixture
          @model = model
          @max_tokens = max_tokens
          @toolset = Toolset.new([])
        end

        # @return [Array(Float, Integer, Integer)] score, tokens, cache_writes
        def measure(shape:, density:, run:)
          density == :none ? reactive(run) : plan_shaped(shape, density, run)
        end

        # The scripted assistant turn: the file the step produced, in the arm's
        # FILE...END convention, so the produced content also sizes the context
        # the NEXT turn resends. Public so the nested ScriptedStep shares it.
        def self.assistant_content(path, content)
          [{ "type" => "text", "text" => "FILE #{path}\n#{content}\nEND" }]
        end

        private

        # The plan-shaped arms: drive the real {Plan::Runner} under the shape's
        # policy, measuring tokens inside the scripted step and cache-writes over
        # the mainline continuation chain the run reports.
        def plan_shaped(shape, density, run)
          store = Store.new
          step = ScriptedStep.new(run:, gold: @fixture.gold, toolset: @toolset)
          report = runner(shape, density, store, step).run(timeline: Timeline.empty(store:), pipeline: BASE_PIPELINE)
          [score(run), step.tokens, mainline_writes(report.continuations, store)]
        end

        def runner(shape, density, store, step)
          Plan::Runner.new(document: @fixture.document_for(density), policy: policy_for(shape, store),
                           agent_step: step, model: @model, max_tokens: @max_tokens)
        end

        def policy_for(shape, store)
          return Plan::ForkPerStep.new(mainline: Timeline.empty(store:)) if shape == :fork
          return Plan::LinearRewrite.new if shape == :linear

          raise ArgumentError, "unknown shape #{shape.inspect}"
        end

        # The reactive cache-aware-compaction baseline: no plan seams, one linear
        # timeline, and {Compaction::Scheduler#pipeline} choosing per turn whether
        # this turn's render gains a Compact stage. Cannot ride {Plan::Runner}
        # faithfully -- the Runner fixes one pipeline per chunk, whereas the
        # scheduler re-decides every turn off runtime history size -- so it runs
        # through this equivalent loop, measured identically (renders for tokens,
        # a prefix-digest chain for cache-writes) so the comparison stays honest.
        def reactive(run)
          scheduler = reactive_scheduler
          need = Compaction::Need.new(byte_threshold: REACTIVE_THRESHOLD, window_tokens: 1_000_000)
          folded = step_ids.inject(reactive_seed) do |state, step_id|
            reactive_turn(state, run, step_id, scheduler, need)
          end
          [score(run), folded.fetch(:tokens), Rewrites.new(chains: folded.fetch(:chain)).count]
        end

        def reactive_seed = { timeline: Timeline.empty, tokens: 0, chain: [] }

        def reactive_turn(state, run, step_id, scheduler, need)
          timeline = state.fetch(:timeline)
          request = render(timeline, reactive_pipeline(timeline, scheduler, need))
          { timeline: commit_step(timeline, run, step_id),
            tokens: state.fetch(:tokens) + Canonical.dump(request.messages).bytesize,
            chain: state.fetch(:chain) + [[Request::PREFIX_CHAIN_VERSION, request.prefix_digests]] }
        end

        # This turn's render pipeline, chosen by the reactive scheduler off the
        # CANDIDATE-FOR-DROP head -- exactly what Compact would elide, so Need, the
        # scheduler's force check, and Compact all threshold the SAME bytes and
        # never disagree about whether this turn compacts.
        def reactive_pipeline(timeline, scheduler, need)
          candidate = timeline_messages(timeline)[0...-REACTIVE_KEEP_LAST]
          scheduler.pipeline(need: need.check(messages: candidate), cold: false,
                             history_size: Canonical.dump(candidate).bytesize,
                             base: BASE_PIPELINE, messages: candidate)
        end

        def reactive_scheduler
          compact = Context::Compact.new(threshold: REACTIVE_THRESHOLD, keep_last: REACTIVE_KEEP_LAST,
                                         summarizer: Plan::ClosureSummary.new(text: REACTIVE_SUMMARY))
          Compaction::Scheduler.new(compact:, hard_cap: REACTIVE_THRESHOLD)
        end

        # The gold grader over the run's produced trajectory -- arm-invariant (the
        # work product depends only on the run), so the score column reports "no
        # shape corrupted the output" and the cost columns carry the shape signal.
        def score(run)
          @fixture.gold.trajectory_grader.grade(ArmTasks::Trajectory.new(files: run.files)).score
        end

        # Rewrites over the mainline: render each continuation (its timeline
        # through its pipeline) into a request and count the prefix rewrites across
        # the chain -- exactly the churn projection P3's seam-policy spec pins.
        def mainline_writes(continuations, store)
          chain = continuations.map do |continuation|
            request = render(continuation.timeline(store), continuation.pipeline)
            [Request::PREFIX_CHAIN_VERSION, request.prefix_digests]
          end
          Rewrites.new(chains: chain).count
        end

        def render(timeline, pipeline)
          Context.new(model: @model, max_tokens: @max_tokens, pipeline:)
                 .render(timeline:, toolset: @toolset, workspace: Workspace.empty)
        end

        def step_ids = @fixture.document_for(:none).map(&:id)

        def timeline_messages(timeline)
          timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }
        end

        def commit_step(timeline, run, step_id)
          timeline
            .commit(role: "user", content: [{ "type" => "text", "text" => "please implement #{step_id}" }])
            .commit(role: "assistant", content: Driver.assistant_content(run.file_for(step_id),
                                                                         run.content_for(step_id)))
        end

        # The agent for one plan step, over the Runner-built Context so the render
        # reflects the live shape pipeline. It measures the resent context, commits
        # a user+assistant pair (the assistant writes the scripted file), and
        # grades the file against its own gold for the step's closure status.
        class ScriptedStep
          attr_reader :tokens

          def initialize(run:, gold:, toolset:)
            @run = run
            @gold = gold
            @toolset = toolset
            @tokens = 0
          end

          def call(step:, timeline:, context:, workspace:)
            @tokens += Canonical.dump(context.render(timeline:, toolset: @toolset, workspace:).messages).bytesize
            path = @run.file_for(step.id)
            content = @run.content_for(step.id)
            advanced = timeline
                       .commit(role: "user", content: [{ "type" => "text", "text" => "please implement #{step.id}" }])
                       .commit(role: "assistant", content: Driver.assistant_content(path, content))
            Plan::Runner::Outcome.new(timeline: advanced, grade: @gold.grade_file(path, content))
          end
        end
        private_constant :ScriptedStep
      end
    end
  end
end
