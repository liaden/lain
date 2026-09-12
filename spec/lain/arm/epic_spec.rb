# frozen_string_literal: true

require "stringio"

# The driver, as this arm drives it: it journals the decisions and transitions a
# real run of the epic would, then answers what each issue came to.
# {Lain::CLI::EpicDriver::Factory#run(width:, budget:)} is the duck.
class EpicSpecDriver
  attr_reader :runs, :widths

  def initialize(result, journal:, decisions: [], transitions: [])
    @result = result
    @journal = journal
    @decisions = decisions
    @transitions = transitions
    @runs = 0
    @widths = []
  end

  def run(width: nil, budget: nil)
    @runs += 1
    @widths << [width, budget]
    (@decisions + @transitions).each { |record| @journal.record(record) }
    @result
  end
end

# The top of the ladder: a whole epic, walked by the driver `/implement-epic`
# drives, with a gate in front of every stage. It has TWO entries on the bench
# and they differ in ONE thing only -- who answers those gates:
#
#   progressive  the human's own policy map, or an earlier run's answers
#                replayed verbatim through {Approval::Gate::RecordedPolicy};
#   hands-off    {Approval::Gate::Policy::HandsOff} at every gate, nobody asked.
#
# Same rungs, same driver, same fixture: only the answers differ, which is what
# makes the pair a measurement rather than two unrelated runs.
RSpec.describe Lain::Arm::Epic do
  let(:zero_clock) { Lain::Arm::Instrument.new(clock: -> { 0.0 }) }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  let(:result) do
    Lain::CLI::EpicDriver::Run::Result.new(
      landed: [Lain::CLI::EpicDriver::Run::Landed.new(issue_id: "a", sha: "a" * 40)],
      reported: [Lain::CLI::EpicDriver::Run::Reported.new(issue_id: "b", reason: "it is still pending")],
      stopped: nil
    )
  end

  let(:grader) { Lain::Grader::Fixture.new("settled") { |f| f.check("ran at all") { true } } }
  let(:spawn_seam) { ->(**) { raise "the epic arm drives the driver, and spawns nothing itself" } }

  def records = journal_io.string.lines

  # The epic's own gate decisions, as a run of it really journals them: one per
  # stage, each naming the policy that reached it.
  def decide(stage, policy:, approved: true, issue_id: nil, digest: "blake3:#{stage}")
    Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug: "demo", stage:, approved:,
                                     answered_by: policy, policy:, latency: 0.0, issue_id:)
  end

  def driver_for(**) = EpicSpecDriver.new(result, journal:, **)

  def arm_over(driver, name: "epic-hands-off", grades: nil)
    described_class.new(name:, driver:, slug: "demo", instrument: zero_clock, records: -> { records },
                        grades: grades || -> { graded_issues })
  end

  # One Grade per issue, as the driver's own grading hook collects them: in
  # production a {Lain::Grader::LeaseHarness} bound to that issue's leased
  # checkout. Scripted here, because what this file is about is what the ARM
  # does with them once it has them.
  def graded_issues
    { "a" => Lain::Grader::Grade.new(score: 1.0, pass: true, why: "all 3 examples passed"),
      "b" => Lain::Grader::Grade.new(score: 0.5, pass: false, why: "1/2 examples passed; failed: refunds") }
  end

  def run_arm(driver, **) = arm_over(driver, **).run("implement the demo epic", spawn_seam:, grader:)

  describe "where it enters the ladder" do
    it "enters at research, so it walks the whole ladder" do
      expect(described_class::ENTRY).to eq("research")
      expect(arm_over(driver_for).rungs).to eq(%w[research epic_plan issue_plan implementation land])
    end

    # The pair differs in policy, never in which rungs it visits -- the confound
    # a bench comparing them must not introduce.
    it "visits the same rungs whichever entry it is built as" do
      expect(arm_over(driver_for, name: "epic-progressive").rungs).to eq(arm_over(driver_for).rungs)
    end
  end

  describe "#run — the driver carries the epic" do
    # It answers the Run DUCK rather than being an {Lain::Arm::Run} itself: this
    # arm carries two metrics that value does not model (rework and
    # round-trips), and widening the shared Run to suit one topology is the
    # altitude mistake the Arm seam exists to avoid. Every reader
    # {Lain::Arm::Driver} folds is answered here.
    it "answers everything the driver folds a run by, naming this arm" do
      run = run_arm(driver_for)

      expect(run.arm).to eq("epic-hands-off")
      expect(run.grade).to be_a(Lain::Grader::Grade)
      expect(run).to respond_to(:timeline, :elapsed, :ledger, :score, :total_tokens, :cost)
      expect(run.elapsed).to eq(0.0)
    end

    it "drives the epic exactly once" do
      driver = driver_for

      run_arm(driver)

      expect(driver.runs).to eq(1)
    end

    # ONE GRADER FOR EVERY ARM. The verdict is the per-issue grades the driver's
    # own hook collected -- the subject's own suite, run in each issue's
    # checkout while its lease still stood -- rolled up. Never the fraction of
    # issues that happened to land, which measures the loop rather than the work
    # and cannot be compared against a linear arm's row.
    it "grades by rolling up the per-issue grades its driver collected" do
      run = run_arm(driver_for)

      expect(run.grade.score).to eq(0.75)
      expect(run.grade.why).to include("a").and include("b").and include("1/2 examples passed")
    end

    # A run that landed nothing still RAN: its issues were worked and graded, so
    # the bench records those grades along with the spend.
    it "grades a run that landed nothing from the grades it did collect" do
      stranded = Lain::CLI::EpicDriver::Run::Result.new(
        landed: [], reported: [Lain::CLI::EpicDriver::Run::Reported.new(issue_id: "a", reason: "gate parked")],
        stopped: "the run was interrupted"
      )
      graded = { "a" => Lain::Grader::Grade.new(score: 0.5, pass: false, why: "1/2 examples passed") }

      run = arm_over(EpicSpecDriver.new(stranded, journal:), grades: -> { graded })
            .run("implement", spawn_seam:, grader:)

      expect(run.grade.score).to eq(0.5)
      expect(run.grade).not_to be_pass
    end

    # A ZERO THAT MEANS "DIDN'T RUN" is the failure a bench exists to prevent.
    # An epic that never started must refuse, so the report can say "not
    # measured" rather than render a 0.000 that reads exactly like an epic which
    # ran and failed every issue.
    it "refuses a run that carried no issue at all, rather than scoring it zero" do
      empty = Lain::CLI::EpicDriver::Run::Result.new(landed: [], reported: [], stopped: "the run was interrupted")

      expect { arm_over(EpicSpecDriver.new(empty, journal:), grades: -> { {} }).run("implement", spawn_seam:, grader:) }
        .to raise_error(described_class::NeverRan, /no issue/)
    end

    # The same rule one step along: the issues ran, but nothing could be graded.
    # {Lain::Grader::LeaseHarness.rolled_up} already refuses to fold nothing, and
    # this arm lets that refusal stand rather than inventing a number.
    it "refuses when its driver collected no grade at all" do
      expect { run_arm(driver_for, grades: -> { {} }) }
        .to raise_error(Lain::Grader::LeaseHarness::NothingGraded)
    end
  end

  # Scenario: hands-off runs the whole ladder with no human, and progressive
  # replays recorded answers.
  describe "who answers the gates" do
    def journalled = Lain::Journal.records(records, type: Lain::Approval::SignoffQueue::JOURNAL_TYPE).to_a

    it "has every hands-off decision carry the hands_off policy, with no human asked" do
      run_arm(driver_for(decisions: Lain::Epic::STAGES.map { |stage| decide(stage, policy: "hands_off") }))

      expect(journalled.map { |record| record["policy"] }.uniq).to eq(["hands_off"])
      expect(journalled.map { |record| record["stage"] }).to eq(Lain::Epic::STAGES)
    end

    # Progressive replays what a human already answered, verdict for verdict --
    # including the denial, which is the one a hands-off run can never produce.
    it "has progressive's decisions match the recording, denial included" do
      recorded = [decide("research", policy: "recorded"),
                  decide("epic_plan", policy: "recorded", approved: false),
                  decide("epic_plan", policy: "recorded", digest: "blake3:epic_plan_again")]

      run_arm(driver_for(decisions: recorded), name: "epic-progressive")

      expect(journalled.map { |record| record["approved"] }).to eq([true, false, true])
      expect(journalled.map { |record| record["policy"] }.uniq).to eq(["recorded"])
    end
  end

  # Scenario (the last clause): both report rework and round-trips. They are
  # FOLDS of the run's own journal, so the arm is what makes them available -- a
  # gate answered twice at one stage is a round-trip, whoever answered it.
  describe "the epic metrics a run leaves behind" do
    it "counts every gate decision at a stage as a round-trip" do
      decisions = [decide("issue_plan", policy: "hands_off", issue_id: "a", approved: false),
                   decide("issue_plan", policy: "hands_off", issue_id: "a", digest: "blake3:second")]

      run = run_arm(driver_for(decisions:))

      expect(run.round_trips(stage: "issue_plan", issue_id: "a")).to eq(2)
    end

    it "counts an issue moving back out of done as rework" do
      transitions = [Lain::Epic::IssueTransition.new(epic_slug: "demo", issue_id: "a",
                                                     from_status: "done", to_status: "pending")]

      run = run_arm(driver_for(decisions: [decide("implementation", policy: "hands_off", issue_id: "a")],
                               transitions:))

      expect(run.rework(issue_id: "a")).to eq(1)
      expect(run.round_trips(stage: "implementation", issue_id: "a")).to eq(1)
    end

    # A bench row is an ARM over a suite, with nowhere to put a per-issue
    # breakdown -- so the run totals both metrics across every issue it carried,
    # landed and merely reported alike.
    it "totals both metrics across every issue the run carried" do
      transitions = [Lain::Epic::IssueTransition.new(epic_slug: "demo", issue_id: "a",
                                                     from_status: "done", to_status: "pending")]
      decisions = [decide("issue_plan", policy: "hands_off", issue_id: "a"),
                   decide("implementation", policy: "hands_off", issue_id: "a", digest: "blake3:impl"),
                   decide("research", policy: "hands_off")]

      run = run_arm(driver_for(decisions:, transitions:))

      expect(run.rework_total).to eq(1)
      expect(run.round_trips_total).to eq(3)
    end
  end
end
