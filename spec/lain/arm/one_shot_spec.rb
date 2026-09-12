# frozen_string_literal: true

# A grader whose verdict is fixed, standing in for the subject's own suite.
# {Lain::Grader::Fixture} freezes itself at construction, so a scripted verdict
# has to be its own object rather than a singleton method on one.
class OneShotSpecJudge
  def initialize(verdict) = (@verdict = verdict)
  def grade(_subject) = @verdict
end

# A real Channel that also records what went past. {Lain::Arm::Instrument#price}
# DRAINS the run's journal to price it, so a plain recorder -- which answers no
# `#drain` at all -- cannot stand in for one. This is Bench::ArmSweep's own tee
# shape, `<<` re-aliased because Channel early-binds its alias to the parent.
class OneShotSpecTee < Lain::Channel
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

# The lowest rung of the decomposition ladder: one agent, handed the whole task
# in the checkout its lease cut, with NO gate in front of it and no plan behind
# it. It is the altitude bench's floor -- whatever the richer arms buy, they buy
# it against this.
#
# Driven over Provider::Mock throughout: the arm spends real money in
# production, so its specs script the provider and never resolve a live one.
RSpec.describe Lain::Arm::OneShot do
  subject(:arm) { described_class.new(instrument: zero_clock) }

  let(:zero_clock) { Lain::Arm::Instrument.new(clock: -> { 0.0 }) }
  let(:spawned) { [] }

  # The widened spawn duck every arm speaks. It records the worker_env it was
  # handed, which is how "the agent worked in the lease's checkout" becomes an
  # assertion rather than a hope.
  let(:spawn_seam) do
    lambda do |journal:, worker_env: nil, **|
      spawned << worker_env
      Lain::Agent.new(
        provider: Lain::Provider::Mock.new(
          responses: [text_response("done", model: "claude-sonnet-4",
                                            usage: Lain::Usage.new(input_tokens: 100, output_tokens: 20))]
        ),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
        journal:, session: Lain::Session.new(worker_env: worker_env || Lain::WorkerEnv.default)
      )
    end
  end

  let(:grader) do
    Lain::Grader::Fixture.new("settled") do |f|
      f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
    end
  end

  def run_arm(**) = arm.run("add a refund to Order", spawn_seam:, grader:, **)

  def leasing(lease) = instance_double(Lain::Isolation::Null, acquire: lease)

  describe "where it enters the ladder" do
    # Scenario (first half): one-shot has no gates. It enters BELOW every gated
    # stage, so there is no rung at which a gate could stand.
    it "enters at implementation, so its rungs are implementation and land alone" do
      expect(described_class::ENTRY).to eq("implementation")
      expect(arm.rungs).to eq(%w[implementation land])
    end

    it "never visits research, epic_plan or issue_plan" do
      expect(arm.rungs).not_to include("research", "epic_plan", "issue_plan")
    end
  end

  describe "#run — the whole task, in one ask" do
    it "returns an Arm::Run over one linear user->assistant Timeline" do
      run = run_arm

      expect(run).to be_a(Lain::Arm::Run)
      expect(run.arm).to eq("one-shot")
      expect(run.timeline.to_a.map(&:role)).to eq(%w[user assistant])
    end

    it "prices the turns the run actually produced" do
      expect(run_arm.total_tokens).to eq(120)
    end

    it "grades the settled timeline with the injected grader" do
      expect(run_arm.grade).to be_pass
    end
  end

  # Scenario: the one-shot run journals no gate decision.
  #
  # Observed on the journal the run really wrote, not argued from the absence of
  # a collaborator: the arm drains its own journal to price the run, so the spec
  # hands it one it can still read afterwards.
  describe "no gate stands in front of it" do
    let(:tee) { OneShotSpecTee.new }

    it "journals turn usage and not one gate decision" do
      described_class.new(instrument: zero_clock, journal_factory: -> { tee })
                     .run("add a refund to Order", spawn_seam:, grader:)

      types = tee.seen.map { |event| event.to_journal["type"] }

      expect(tee.seen).not_to be_empty
      expect(tee.seen.grep(Lain::Approval::GateDecision)).to be_empty
      expect(types).to include("turn_usage")
      expect(types).not_to include("gate_decision")
    end
  end

  describe "the lease it works in" do
    it "hands the agent the lease's own worker_env, so the work lands in the checkout" do
      lease = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.tmpdir, env: {}))

      run_arm(isolation: leasing(lease))

      expect(spawned).to eq([lease.worker_env])
    end

    it "acquires a lease and releases it exactly once" do
      released = []
      lease = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default, on_release: -> { released << :once })

      run_arm(isolation: leasing(lease))

      expect(lease).to be_released
      expect(released).to eq([:once])
    end

    # The altitude bench grades an arm by the SUBJECT'S own suite, which can
    # only run while the lease still holds the checkout -- so the arm builds its
    # judge from the lease it took rather than grading the transcript.
    it "builds its judge from the lease it is holding, and grades with what that answers" do
      held = []
      verdict = Lain::Grader::Grade.new(score: 0.5, pass: false, why: "1/2 examples passed")
      grading = lambda do |lease:, **|
        held << lease
        OneShotSpecJudge.new(verdict)
      end
      lease = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default)

      run = described_class.new(instrument: zero_clock, grading:)
                           .run("add a refund", spawn_seam:, grader:, isolation: leasing(lease))

      expect(held).to eq([lease])
      expect(run.grade).to eq(verdict)
    end

    # Unwired, it grades with exactly what the Driver threaded in -- so this arm
    # inside an ordinary `bench arms`-shaped comparison is unchanged.
    it "falls through to the Driver's own grader when no grading seam is given" do
      expect(run_arm.grade.why).to include("committed an assistant turn")
    end
  end
end
