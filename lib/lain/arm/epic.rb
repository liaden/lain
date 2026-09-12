# frozen_string_literal: true

module Lain
  class Arm
    # The top of the ladder: a whole epic, walked by the same driver
    # `/implement-epic` drives, with a gate in front of every stage.
    #
    # It has TWO entries on the altitude bench, and they differ in ONE thing --
    # who answers those gates. Progressive runs the human's own policy map, or an
    # earlier run's answers replayed verbatim through
    # {Approval::Gate::RecordedPolicy}; hands-off runs
    # {Approval::Gate::Policy::HandsOff} at every gate, with nobody asked. Both
    # walk the SAME rungs in the same order, which is what makes the pair a
    # measurement of gating rather than two unrelated runs: the policy is carried
    # by the driver this arm is handed, never by the ladder.
    #
    # It SPAWNS NOTHING ITSELF. The driver owns the loop -- issue actors, gates,
    # the landing queue -- so this arm's whole job is to run it once, price what
    # it spent, and fold its journal into the two metrics an epic has that no
    # other arm does.
    class Epic < Arm
      # Where it joins {Ladder}: the first rung, so it walks the whole thing.
      ENTRY = "research"

      # The run carried no issue at all -- interrupted before it started, or an
      # epic with nothing runnable in it. Refused rather than scored, because a
      # 0.000 in the report reads exactly like an epic that ran and failed every
      # issue, and telling those two apart is the whole point of a bench.
      # {Grader::LeaseHarness.rolled_up} states the same rule for grades; this is
      # it one step earlier.
      class NeverRan < Lain::Error; end

      # What a bench reads an epic run by, beyond the four metrics every arm
      # carries. A DECORATOR over {Arm::Run} rather than a wider Run: rework and
      # round-trips are one topology's facts, and growing the shared value to
      # carry them is exactly the altitude mistake the Arm seam exists to avoid.
      # Every reader {Driver} folds a run by is delegated explicitly -- no
      # `method_missing`, so a reader this forgets fails loudly at the call.
      Outcome = Data.define(:inner, :metrics, :slug, :issues) do
        def arm = inner.arm
        def timeline = inner.timeline
        def grade = inner.grade
        def elapsed = inner.elapsed
        def ledger = inner.ledger
        def score = inner.score
        def usage = inner.usage
        def total_tokens = inner.total_tokens
        def cost = inner.cost
        def compare_run = inner.compare_run

        # @param issue_id [String] the issue to read
        # @return [Integer] how often this issue's settled work was reopened
        def rework(issue_id:) = metrics.rework(epic_slug: slug, issue_id:)

        # @param stage [String] the stage whose gate is read
        # @param issue_id [String, nil] nil reads an epic-wide decision
        # @return [Integer] how many gate decisions that stage took
        def round_trips(stage:, issue_id: nil) = metrics.round_trips(epic_slug: slug, stage:, issue_id:)

        # The bench's own columns: one number per run rather than per issue,
        # since a report row is an ARM over a suite and has nowhere to put a
        # per-issue breakdown.
        #
        # @return [Integer] rework across every issue this run carried
        def rework_total = issues.sum { |issue_id| metrics.rework(epic_slug: slug, issue_id:) }

        # Root-qualified: a class named {Epic} inside {Lain::Arm} SHADOWS
        # `Lain::Epic` for everything lexically within it, so a bare
        # `Epic::STAGES` here would look up `Lain::Arm::Epic::STAGES`.
        #
        # @return [Integer] gate decisions across every stage, epic-wide and
        #   issue-scoped alike
        def round_trips_total = ::Lain::Epic::STAGES.sum { |stage| trips_at(stage) }

        private

        def trips_at(stage)
          metrics.round_trips(epic_slug: slug, stage:, issue_id: nil) +
            issues.sum { |issue_id| metrics.round_trips(epic_slug: slug, stage:, issue_id:) }
        end
      end

      # @param driver [#run] `run(width:, budget:) -> CLI::EpicDriver::Run::Result`,
      #   the epic loop already built with the gate policy this entry is for
      # @param slug [String] the epic being walked, which is the scope both
      #   metrics are keyed on
      # @param name [String] the arm's label -- what tells the two entries apart
      # @param instrument [Instrument] times the whole drive and prices it
      # @param records [#call] answers this run's journal entries, re-read after
      #   the drive so the fold sees what the drive just wrote
      # @param width [Integer, nil] how many issues the driver carries at once;
      #   nil leaves the driver's own default
      # @param budget [Integer, nil] how many issues the run may land
      # @param synthesis [Synthesis] re-attributes the driver's spend onto a
      #   head this run can reach
      # @param grades [#call] answers `{issue_id => Grade}`, the per-issue
      #   verdicts the driver's own grading hook collected -- in production a
      #   {Grader::LeaseHarness} bound to each issue's leased checkout. Read
      #   AFTER the drive, because that is when the hook has run.
      # @param handoff [#reclaim, #surrender] forwarded to the base's lease bracket
      def initialize(driver:, slug:, name: "epic", instrument: Instrument.new, records: -> { [] },
                     width: nil, budget: nil, synthesis: Synthesis.new, grades: -> { {} },
                     handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @driver = driver
        @slug = slug
        @instrument = instrument
        @records = records
        @knobs = { width:, budget: }.compact
        @synthesis = synthesis
        @grades = grades
      end

      # @return [Array<String>] the whole ladder, research through land
      def rungs = Ladder.from(ENTRY)

      # Drive the epic once and hand back the graded, priced, timed {Outcome}.
      #
      # `spawn_seam`, `grader` and `grading` are accepted and unused, because
      # this topology's agents are spawned by the driver's own issue actors and
      # graded there: the per-issue judge is bound at the DRIVER, through its
      # grading hook, and reaches this arm as the grades it rolls up. Accepting
      # the keywords keeps one call shape across every arm a bench drives.
      #
      # @param task [String] what the run is, for the lead turn's record
      # @param spawn_seam [#call] unused; the driver spawns its own actors
      # @param grader [#grade] unused; the verdict is the rolled-up per-issue grades
      # @param isolation [#acquire] the injected backend
      # @param grading [#call] unused; this arm's judge is bound at the driver
      # @return [Outcome]
      # @raise [NeverRan] when the run carried no issue at all
      def run(task, spawn_seam: nil, grader: nil, isolation: NoIsolation, grading: nil) # rubocop:disable Lint/UnusedMethodArgument
        leased(isolation:) do |_lease|
          elapsed, result = @instrument.timed { @driver.run(**@knobs) }
          carried!(result)
          measured(result, folded: @synthesis.fold(lead_for(task), [drove(result)]), elapsed:)
        end
      end

      private

      # The arm's own lead: one user turn naming the run, and the head every
      # re-attributed payment is keyed onto.
      def lead_for(task)
        Timeline.empty(store: Store.new).commit(role: :user, content: [{ "type" => "text", "text" => task }])
      end

      # `head_digest: nil` because the driver's actors commit into Stores this
      # arm does not hold: nothing is named causally, while the spend still
      # re-attributes onto a head the run can reach.
      def drove(result)
        Synthesis::Result.ok(head_digest: nil, text: result.to_s, usage_records: spent)
      end

      def measured(result, folded:, elapsed:)
        Outcome.new(slug: @slug, metrics: Bench::EpicMetrics.from_journal(@records.call),
                    issues: carried(result),
                    inner: Run.new(arm: name, timeline: folded.timeline, grade: graded(result), elapsed:,
                                   ledger: @instrument.price_records(folded.ledger_entries)))
      end

      # Every issue this run touched, landed or merely reported: both are issues
      # whose rework and round-trips were really paid for.
      def carried(result) = (result.landed + result.reported).map(&:issue_id).uniq

      # The driver journals through the chat's own handle rather than through a
      # channel this arm holds, so its spend is read BACK off the record rather
      # than drained. Read by the raw `type` tag, {Bench::EpicMetrics}' own seam.
      def spent = Journal.records(@records.call, type: TURN_USAGE).to_a

      TURN_USAGE = "turn_usage"
      private_constant :TURN_USAGE

      # Nothing to score at all, refused before a Run exists to carry a number.
      def carried!(result)
        return unless result.landed.empty? && result.reported.empty?

        raise NeverRan, "#{name} carried no issue at all, so there is nothing to score -- a 0.000 here would " \
                        "read exactly like an epic that ran and failed every issue"
      end

      # THE SUBJECT'S OWN SUITE IS THE VERDICT, here as for every other arm: the
      # per-issue grades the driver's hook took in each issue's checkout, rolled
      # up. The fraction of issues that LANDED measures the loop rather than the
      # work, and a row measured that way cannot be compared against a linear
      # arm's -- which is the comparison this bench exists to make.
      #
      # `rolled_up` refuses an empty fold rather than inventing a number, and
      # that refusal is left to stand.
      def graded(_result) = Grader::LeaseHarness.rolled_up(@grades.call)
    end
  end
end
