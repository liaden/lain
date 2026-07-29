# frozen_string_literal: true

module Lain
  module Bench
    # Which topologies the live arm comparison puts side by side, and how the
    # orchestrator among them splits a task up: {ArmSweep}'s three, since a
    # comparison is only a comparison against the {Arm::SingleThread} control.
    #
    # A MODULE with a builder rather than a frozen constant map because
    # `lain/bench` loads BEFORE `lain/arm` (see lain.rb) -- these classes exist
    # at call time, not at this file's load time.
    #
    # Each arm keeps its own DEFAULT (real, monotonic) clock. {ArmSweep} zeroes
    # its clock because a replayed mock has no parallelism to time, so timing it
    # would fabricate a number; a live run has real fan-out, and wall-time is one
    # of the three metrics {Arm::Driver} reports -- zeroing it here would erase
    # the measurement the live path exists to take.
    module LiveArms
      # A path a task names: `lib/widget.rb`, `config/a.yml`, `lib/utils/slugify.rb`.
      # The trailing `[a-z]{2,4}` is what keeps a version string ("2.1.0") and a
      # sentence boundary out of the set.
      FILE_PATH = %r{\b[\w.-]+(?:/[\w.-]+)*\.[a-z]{2,4}\b}
      private_constant :FILE_PATH

      # ONE SUBTASK PER FILE THE TASK NAMES.
      #
      # {Arm::OrchestratorWorker::DEFAULT_DECOMPOSE} splits on LINES, and every
      # prompt in a committed {ArmTasks} fixture is a folded YAML scalar -- one
      # line, so one worker, so an orchestrator arm that never orchestrates and a
      # report column that is silently a second copy of the control. That default
      # is why the replayed sibling injects its own (`arm_sweep.rb:135-138`), and
      # inheriting it here would have shipped a structurally inert arm on the
      # path that spends real money.
      #
      # The FILE is the suite's own unit of independence -- `gold_files` is keyed
      # by path, and a `:parallel` task is defined as one whose "each file's edit
      # needs zero context from any other" -- so that is what one worker gets.
      #
      # Each worker is briefed with the WHOLE task and told which file is its
      # share, rather than handed a bare path no one could act on. That
      # deliberately does not starve a worker of context: measuring
      # context-starvation wants a different decomposition, and choosing one is a
      # bench-methodology decision, not this seam's to make.
      #
      # A task naming no path is not split at all -- one worker doing the whole
      # thing beats N workers doing nothing.
      DEFAULT_DECOMPOSE = lambda do |task|
        paths = task.to_s.scan(FILE_PATH).uniq
        return [task.to_s] if paths.empty?

        paths.map { |path| "#{task}\n\nYour share of this task is #{path}, and only #{path}." }
      end

      # @param price_book [Lain::PriceBook] prices each arm's journal
      # @param decompose [#call] `call(task) -> Array<String>`, the orchestrator's
      #   split; the linear arms have nothing to decompose
      # @return [Array<Lain::Arm>] single-thread control first
      def self.build(price_book: PriceBook.default, decompose: DEFAULT_DECOMPOSE)
        # One instrument, so all three arms report wall-time off the same clock
        # and dollars off the same book -- the comparison is only a comparison
        # if the measuring is shared.
        instrument = Arm::Instrument.new(price_book:)
        [Arm::SingleThread.new(name: "single-thread", instrument:),
         Arm::OrchestratorWorker.new(name: "orchestrator-worker", instrument:, decompose:),
         Arm::DualLedger.new(name: "dual-ledger", instrument:)]
      end
    end
  end
end
