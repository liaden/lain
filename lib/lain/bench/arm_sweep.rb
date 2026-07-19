# frozen_string_literal: true

module Lain
  module Bench
    # B12, the arms bench sweep and the chunk's headline deliverable: the
    # comparison the orchestration papers assert but rarely produce. Runs the
    # three arms -- {Arm::SingleThread} (the CONTROL every arm is measured
    # against), {Arm::OrchestratorWorker}, and {Arm::DualLedger} -- over B0's
    # {ArmTasks} suite, driven by committed recorded trajectories through
    # Provider::Mock (deterministic, offline, zero network), and reports grader
    # score, tokens, wall-time, context-loss, and replans/stalls as
    # DISTRIBUTIONS per arm, broken out per category so the pre-registered
    # boundary (procedural favors single-thread; genuinely-parallel work does not
    # penalize orchestration) stays visible instead of averaged away.
    #
    # == What is real and what is replayed
    #
    # The arms run FOR REAL: real Timelines over real Stores, real per-turn
    # journaling priced through a real {Ledger}, the orchestrator's real
    # multi-parent synthesis fan-in, the dual-ledger's real stall/replan
    # LoopMachine. Only the model's WORDS and TOKEN COUNTS are replayed, from the
    # committed {Recordings} -- so the topology under study is genuine while the
    # eval spends nothing and repeats byte-identically. One {Recordings#seam}
    # object drives all three arms (the base Arm duck), the cross-arm shape the
    # dual_ledger_spec pins.
    #
    # == The two process metrics, and their honest fidelity
    #
    # REPLANS/STALLS are sourced exactly as {Arm::DualLedger}'s own `#price` NOTE
    # prescribes: the Run drains its journal for pricing and discards the
    # `ledger_transition` records, so the sweep injects a `journal_factory:` that
    # TEES every pushed event into a caller-held sink BEFORE that drain, and
    # counts the `replan` transitions there. The linear arms emit none.
    #
    # CONTEXT-LOSS would ideally ride the bench-science lineage projection
    # ({Grader::FrustrationRepair}), but that reads tool-call journals, and these
    # arms carry an empty toolset -- no tool calls, so nothing for the projection
    # to attribute. So the sweep falls back to a documented Journal heuristic
    # (its reduced fidelity stated in the report, not silently dropped): a
    # context-loss event is a produced file whose content DIVERGES from the
    # single-thread control's for the same path -- context the decomposing arm
    # lost by working a slice in isolation. The control never diverges from
    # itself, which is exactly why it is the control.
    class ArmSweep
      # A missing recordings fixture -- a checkout or packaging mistake, never
      # user input to refuse. Named and path-bearing like {DeciderSweep::MissingFixture}.
      class MissingFixture < Lain::Error; end

      # A recording that names no task in the suite, is missing a required
      # field, or is asked a prompt it never recorded -- a malformed fixture is
      # a bug to surface loudly, never a task silently skipped or mis-scored.
      class MalformedRecording < Lain::Error; end

      # One (arm, task) cell: the metrics the sweep folds into per-arm
      # distributions. `score`/`tokens` come off the real {Arm::Run};
      # `context_loss`/`replans` are the two process metrics.
      Measurement = Data.define(:arm, :task_id, :category, :score, :tokens, :context_loss, :replans)

      # Report-row order; single-thread first, because it is the control.
      ARM_ORDER = %w[single-thread orchestrator-worker dual-ledger].freeze

      # Wall-time is measured but never reported here: a mock replay has no real
      # parallelism to time, so timing it would fabricate a number. A constant
      # clock keeps the (unreported) elapsed deterministic too.
      ZERO_CLOCK = -> { 0.0 }
      private_constant :ZERO_CLOCK

      # @param tasks_path [String] the committed {ArmTasks} suite fixture
      # @param recordings_path [String] the committed per-task recordings fixture
      # @param price_book [PriceBook] prices each run's journal (tokens only are reported)
      def initialize(tasks_path:, recordings_path:, price_book: PriceBook.default)
        @tasks = ArmTasks.new(fixture_path: tasks_path)
        @recordings = Recordings.new(path: recordings_path, tasks: @tasks)
        @price_book = price_book
      end

      # The Compare-style report as a String -- never printed (output
      # discipline). Memoized so "report twice" is byte-identical for free, the
      # guarantee every sweep gives.
      # @return [String]
      def report = @report ||= Report.new(measurements, order: @recordings.order).to_s

      # One {Measurement} per (arm, task), in fixture order. Exposed so the
      # process-metric invariants are checkable numerically, the way
      # {DeciderSweep#timelines} exposes its isolation invariant.
      # @return [Array<Measurement>]
      def measurements
        @measurements ||= @recordings.order.flat_map { |id| measure_task(@recordings.task_for(id)) }.freeze
      end

      # The `path => content` Trajectory an arm's assistant turns produced,
      # parsed off the recorded FILE...END blocks -- what ArmTasks' gold grader
      # scores and what context-loss diffs against the control.
      # @return [ArmTasks::Trajectory]
      def self.trajectory(timeline)
        text = timeline.to_a.select { |turn| turn.role == "assistant" }
                            .flat_map(&:content).filter_map { |block| block["text"] }.join("\n")
        ArmTasks::Trajectory.new(files: FileBlocks.parse(text))
      end

      private

      def measure_task(task)
        grader = GraderAdapter.new(task)
        control = single_thread.run(task.prompt, spawn_seam:, grader:)
        control_files = self.class.trajectory(control.timeline).files
        [cell("single-thread", task, control, control_files, replans: 0),
         cell("orchestrator-worker", task, orchestrator.run(task.prompt, spawn_seam:, grader:), control_files,
              replans: 0),
         measure_dual_ledger(task, grader, control_files)]
      end

      def measure_dual_ledger(task, grader, control_files)
        sink = []
        run = dual_ledger(sink).run(task.prompt, spawn_seam:, grader:)
        replans = sink.count { |event| event.is_a?(Arm::DualLedger::LedgerTransition) && event.event == :replan }
        cell("dual-ledger", task, run, control_files, replans:)
      end

      def cell(arm, task, run, control_files, replans:)
        files = self.class.trajectory(run.timeline).files
        diverged = (files.keys & control_files.keys).count { |path| files[path] != control_files[path] }
        Measurement.new(arm:, task_id: task.id, category: task.category,
                        score: run.score, tokens: run.total_tokens, context_loss: diverged, replans:)
      end

      def spawn_seam = @spawn_seam ||= @recordings.seam

      def single_thread
        @single_thread ||= Arm::SingleThread.new(name: "single-thread", clock: ZERO_CLOCK, price_book: @price_book)
      end

      def orchestrator
        @orchestrator ||= Arm::OrchestratorWorker.new(
          name: "orchestrator-worker", clock: ZERO_CLOCK, price_book: @price_book,
          decompose: ->(task) { @recordings.subtasks_for(task) }
        )
      end

      def dual_ledger(sink)
        Arm::DualLedger.new(name: "dual-ledger", clock: ZERO_CLOCK, price_book: @price_book,
                            journal_factory: -> { Tee.new(sink) })
      end

      # Grades a Timeline by parsing its produced files into the Trajectory
      # ArmTasks' gold {Grader::Fixture} scores -- the bridge from the Arm seam's
      # `grade(timeline)` duck to B0's file-shaped grader.
      class GraderAdapter
        def initialize(task) = (@task = task)

        def grade(timeline) = @task.grader.grade(ArmSweep.trajectory(timeline))
      end
      private_constant :GraderAdapter

      # A Channel that mirrors every pushed event into a caller-held sink before
      # forwarding it, so the dual-ledger's journaled `ledger_transition` records
      # are observed BEFORE the Run drains the journal for pricing. Channel's
      # `alias << push` early-binds to the parent, so `<<` (which the arm's
      # Journaling listener uses) is re-aliased here to see those writes too --
      # the recording-journal idiom the dual_ledger_spec pins.
      class Tee < Channel
        def initialize(sink)
          super()
          @sink = sink
        end

        def push(event)
          @sink << event
          super
        end
        alias << push
      end
      private_constant :Tee
    end
  end
end

# After the class body: {Recordings} and {Report} reopen ArmSweep (and raise its
# MissingFixture/MalformedRecording, defined above), and nothing in the body
# above needs either before runtime -- the children-after-the-class-body load
# order effect/handler.rb uses. Separate FILES, not nested classes, because
# Metrics/ClassLength counts a nested class's lines as the enclosing class's own.
require_relative "arm_sweep/recordings"
require_relative "arm_sweep/report"
