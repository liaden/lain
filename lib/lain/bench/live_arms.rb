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
    # its clock because a replayed mock has no parallelism to time; a live run
    # has real fan-out, and zeroing it here would erase the measurement the
    # live path exists to take.
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
      # line, so one worker, so an orchestrator arm that never orchestrates and
      # a report column silently a second copy of the control. Inheriting that
      # default would have shipped a structurally inert arm on the path that
      # spends real money, which is why the replayed sibling injects its own.
      #
      # The FILE is the suite's own unit of independence: `gold_files` is keyed
      # by path, and a `:parallel` task is one whose every file's edit needs
      # zero context from any other.
      #
      # Each worker is briefed with the WHOLE task and told which file is its
      # share, rather than handed a bare path no one could act on. That does not
      # starve a worker of context on purpose -- measuring context-starvation
      # wants a different decomposition, and choosing one is a bench-methodology
      # decision, not this seam's to make.
      #
      # A task naming no path is not split at all: one worker doing the whole
      # thing beats N workers doing nothing.
      DEFAULT_DECOMPOSE = lambda do |task|
        paths = task.to_s.scan(FILE_PATH).uniq
        return [task.to_s] if paths.empty?

        paths.map { |path| "#{task}\n\nYour share of this task is #{path}, and only #{path}." }
      end

      # The two epic entries' labels. They differ in WHO answers the gates and in
      # nothing else, so the names are the only thing telling their rows apart.
      PROGRESSIVE = "epic-progressive"
      HANDS_OFF = "epic-hands-off"

      # What the altitude arms need and the orchestration arms do not: how a
      # plan gets written, who carries it, and one already-built driver per epic
      # entry -- each carrying the gate policy that entry is FOR, since the
      # policy belongs to the driver and never to the ladder.
      #
      # A value rather than nine keywords on {.altitude}: they arrive together,
      # they are threaded together, and a roster assembled from loose arguments
      # is one where two arms can differ by a seam nobody passed.
      # `grades` is what makes the epic rows READABLE. Both epic arms score by
      # rolling up the per-issue grades their driver's grading hook collected,
      # and an arm that rolled up none refuses -- correctly, but that prints
      # "not measured" in every cell. Unthreaded, the only roster this builds
      # could never show a four-arm comparison at all.
      Seams = Data.define(:planner, :actors, :supervisor, :progressive, :hands_off, :slug, :records,
                          :grading, :layout, :grades) do
        # `grading` and `layout` default to nil rather than to the objects they
        # stand for: `bench` loads BEFORE `arm` and `grader`, so a default naming
        # either here would be a boot-time NameError. {.altitude} resolves them
        # in a method body, where those units exist.
        def initialize(planner:, actors:, supervisor:, progressive:, hands_off:, slug:,
                       records: -> { [] }, grading: nil, layout: nil, grades: -> { {} })
          super
        end
      end

      # The DECOMPOSITION comparison `lain bench altitude` runs: the same work
      # entered at four different heights on {Arm::Ladder}, lowest rung first, so
      # the report reads from the cheapest entry to the richest.
      #
      # One instrument for all four, {.build}'s own rule and for its own reason:
      # a comparison is only a comparison if the clock and the price book are
      # shared.
      #
      # @param seams [Seams] what the planned and gated arms are driven by
      # @param price_book [Lain::PriceBook] prices every arm's journal
      # @return [Array<Lain::Arm>] one-shot, plan-only, then the two epic entries
      def self.altitude(seams:, price_book: PriceBook.default)
        instrument = Arm::Instrument.new(price_book:)
        [Arm::OneShot.new(instrument:, grading: seams.grading || Arm::OneShot::PASS_THROUGH),
         Arm::PlanOnly.new(instrument:, planner: seams.planner, actors: seams.actors,
                           supervisor: seams.supervisor, layout: seams.layout || TestLayout::None),
         *epic_entries(seams, instrument)]
      end

      # The two epic entries differ in ONE member -- which driver, and so which
      # gate policy -- so they are built from one expression rather than two that
      # could drift. Named because writing them out twice is what put
      # {.altitude} over Metrics/AbcSize.
      def self.epic_entries(seams, instrument)
        [[PROGRESSIVE, seams.progressive], [HANDS_OFF, seams.hands_off]].map do |(name, driver)|
          Arm::Epic.new(name:, driver:, slug: seams.slug, instrument:,
                        records: seams.records, grades: seams.grades)
        end
      end
      private_class_method :epic_entries

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
