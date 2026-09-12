# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock), the
# shape spec/lain/cli/epic_driver/run_spec.rb established for the same actors.

# An issue actor, as this arm sees one: it is only ever asked for identity,
# because the arm retires it through the supervisor.
class PlanOnlySpecActor
  def initialize(id) = @id = id
  attr_reader :id
end

# What one launch left standing -- {Lain::CLI::EpicDriver::IssueActor::Launch}'s
# shape, which is the whole of what this arm reads off a launch.
PlanOnlySpecLaunch = Data.define(:actor, :worker_id, :branch, :tests)

# A grader whose verdict is fixed, standing in for the subject's own suite.
# {Lain::Grader::Fixture} freezes itself at construction, so a scripted verdict
# has to be its own object rather than a singleton method on one.
class PlanOnlySpecJudge
  def initialize(verdict) = (@verdict = verdict)
  def grade(_subject) = @verdict
end

# A real Channel that also records what went past, for the reason the one-shot
# spec's tee carries: {Lain::Arm::Instrument} DRAINS a run's journal to price it.
class PlanOnlySpecTee < Lain::Channel
  attr_reader :seen

  def initialize
    super
    @seen = []
  end

  def push(event)
    @seen << event
    super
  end
  alias << push
end

# The supervisor the arm retires its one actor through, answering the
# {Lain::Isolation::WorkerHandoff::Report} a retirement really answers with.
class PlanOnlySpecSupervisor
  Row = Data.define(:actor)

  def initialize(retired, report: nil)
    @retired = retired
    @report = report
    @rows = []
  end

  def adopt(row)
    @rows << row
    row
  end

  def find(&block) = @rows.find(&block)

  def retire(row)
    @retired << row.actor.id
    @report || Lain::Isolation::WorkerHandoff::Report.new(kind: :declined, ref: "refs/lain/worker/plan-only",
                                                          sha: "c" * 40, detail: "anchored", paths: [],
                                                          fast_forward: false)
  end
end

# One rung up from one-shot: the task is PLANNED first (create-plan), and the
# plan is then carried out by an issue actor running execute-plan -- but there
# is no epic around it, so nothing gates and nothing lands.
#
# Every collaborator is scripted. The planner is a seam, the actor is a seam,
# and no provider is resolved: this arm spends real money in production.
RSpec.describe Lain::Arm::PlanOnly do
  subject(:arm) { described_class.new(instrument: zero_clock, planner:, actors:, supervisor:) }

  # The plan the create-plan step produces, declaring the subject the issue's
  # tests are written for -- the line {Lain::CLI::EpicDriver::PlanSubject} reads.
  let(:plan_text) { "Subject: lib/order.rb\nLevel: unit\n\nAdd a refund to Order.\n" }
  let(:planned) { [] }
  # The create-plan step, as this arm drives it: it really spends a turn through
  # the run's own spawn seam, which is what gives the run something to price.
  let(:planner) do
    lambda do |task, spawn_seam:, journal:, **rest|
      planned << [task, rest]
      spawn_seam.call(journal:).ask(task)
      plan_text
    end
  end

  let(:launched) { [] }
  let(:retired) { [] }

  # An issue actor, as this arm drives one: asked to carry a plan in a checkout
  # of its own, then retired for what it committed.
  let(:actors) do
    lambda do |issue_id, subject:, level: nil, attempt: 1, worker_env: nil|
      launched << { issue_id:, subject:, level:, attempt:, worker_env: }
      actor = PlanOnlySpecActor.new(issue_id)
      supervisor.adopt(PlanOnlySpecSupervisor::Row.new(actor:))
      PlanOnlySpecLaunch.new(actor:, branch: nil, tests: nil,
                             worker_id: "plan-only.#{issue_id}.#{attempt}")
    end
  end

  let(:supervisor) { PlanOnlySpecSupervisor.new(retired) }
  let(:zero_clock) { Lain::Arm::Instrument.new(clock: -> { 0.0 }) }
  let(:grader) { Lain::Grader::Fixture.new("settled") { |f| f.check("ran at all") { true } } }

  let(:spawn_seam) do
    lambda do |journal:, **|
      Lain::Agent.new(
        provider: Lain::Provider::Mock.new(
          responses: [text_response("planned", model: "claude-sonnet-4",
                                               usage: Lain::Usage.new(input_tokens: 60, output_tokens: 10))]
        ),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256), journal:
      )
    end
  end

  def run_arm(**) = arm.run("add a refund to Order", spawn_seam:, grader:, **)

  describe "where it enters the ladder" do
    it "enters at issue_plan, one rung above one-shot" do
      expect(described_class::ENTRY).to eq("issue_plan")
      expect(arm.rungs).to eq(%w[issue_plan implementation land])
    end

    # Scenario (second half): plan-only has no epic. The two epic-wide rungs are
    # exactly the ones it never visits.
    it "never visits the epic's own rungs" do
      expect(arm.rungs).not_to include("research", "epic_plan")
    end
  end

  # Scenario: the plan-only run wrote a plan and ran it in an issue actor.
  describe "#run — plan first, then carry it" do
    it "asks the planner for a plan before any actor is launched" do
      run_arm

      expect(planned.map(&:first)).to eq(["add a refund to Order"])
      expect(launched.size).to eq(1)
    end

    it "hands the issue actor the subject and level the plan itself declared" do
      run_arm

      expect(launched.first).to include(subject: "lib/order.rb", level: "unit")
    end

    # The actor carries the plan out in the checkout this arm is holding -- the
    # same environment the planner was handed. Without it the actor works
    # wherever the process happened to stand, which for a bench is lain's own
    # tree rather than the subject project under test.
    it "hands the issue actor the lease's own worker_env, as it hands the planner one" do
      lease = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.tmpdir, env: {}))

      run_arm(isolation: instance_double(Lain::Isolation::Null, acquire: lease))

      expect(launched.first.fetch(:worker_env)).to be(lease.worker_env)
    end

    it "carries the plan in an issue actor, and retires it for what it committed" do
      run_arm

      expect(retired.size).to eq(1)
    end

    it "returns an Arm::Run naming this arm, graded and priced" do
      run = run_arm

      expect(run).to be_a(Lain::Arm::Run)
      expect(run.arm).to eq("plan-only")
      expect(run.grade).to be_a(Lain::Grader::Grade)
    end

    # The actor's spend sits on ITS timeline, which the arm's own head does not
    # render-reach -- so an arm that simply folded its lead would price a paid
    # actor at zero, the one failure {Lain::Arm::Run}'s reachability contract
    # forbids.
    it "prices the actor's turns, re-attributed onto a head the run can reach" do
      expect(run_arm.total_tokens).to be > 0
    end

    # ONE GRADER FOR EVERY ARM. Scoring a synthesized transcript here while
    # one-shot is scored by the subject's own suite would put two different
    # measurements under a single "score" column, and comparing those rows is
    # the whole thing this bench exists to do.
    it "grades through the judge its grading seam builds from the lease it holds" do
      held = []
      verdict = Lain::Grader::Grade.new(score: 0.5, pass: false, why: "1/2 examples passed")
      lease = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.tmpdir, env: {}))
      grading = lambda do |lease:, **|
        held << lease
        PlanOnlySpecJudge.new(verdict)
      end

      run = described_class.new(instrument: zero_clock, planner:, actors:, supervisor:, grading:)
                           .run("add a refund", spawn_seam:, grader:,
                                                isolation: instance_double(Lain::Isolation::Null, acquire: lease))

      expect(held).to eq([lease])
      expect(run.grade).to eq(verdict)
    end

    # Unwired, it grades with exactly what the Driver threaded in, so this arm
    # inside an ordinary comparison is unchanged.
    it "falls through to the Driver's own grader when no grading seam is given" do
      expect(run_arm.grade).to be_a(Lain::Grader::Grade)
    end
  end

  describe "no epic stands around it" do
    let(:tee) { PlanOnlySpecTee.new }

    it "journals no gate decision and lands nothing" do
      described_class.new(instrument: zero_clock, planner:, actors:, supervisor:,
                          journal_factory: -> { tee })
                     .run("add a refund to Order", spawn_seam:, grader:)

      expect(tee.seen.grep(Lain::Approval::GateDecision)).to be_empty
      expect(tee.seen.map { |event| event.to_journal["type"] }).not_to include("gate_decision")
    end

    # A plan declaring no subject is a plan an issue actor cannot place tests
    # for, so it refuses by name rather than inventing a path.
    it "refuses a plan that declares no subject, launching nothing" do
      undeclared = described_class.new(instrument: zero_clock, actors:, supervisor:,
                                       planner: ->(*, **) { "no declaration here\n" })

      expect { undeclared.run("add a refund", spawn_seam:, grader:) }
        .to raise_error(Lain::CLI::EpicDriver::PlanSubject::Undeclared)
      expect(launched).to be_empty
    end
  end
end
