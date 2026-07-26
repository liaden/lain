# frozen_string_literal: true

# The single-thread control arm wraps Agent#ask on one linear Timeline -- the
# baseline every richer topology has to beat. Driven over Provider::Mock so it
# spends no tokens.
RSpec.describe Lain::Arm::SingleThread do
  subject(:arm) { described_class.new }

  # A FRESH agent per call (Provider::Mock is stateful -- it consumes its
  # scripted responses), journaling into whatever recording channel the arm
  # injects so the run can be priced.
  let(:spawn_seam) do
    lambda do |journal:|
      Lain::Agent.new(
        provider: Lain::Provider::Mock.new(
          responses: [text_response("done", model: "claude-sonnet-4",
                                            usage: Lain::Usage.new(input_tokens: 100, output_tokens: 20))]
        ),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
        journal:
      )
    end
  end

  # Grades the recorded Timeline: a deterministic Fixture, no model in the loop.
  let(:grader) do
    Lain::Grader::Fixture.new("settled") do |f|
      f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
    end
  end

  describe "#run — the graded control run" do
    subject(:run) { arm.run("please echo hi", spawn_seam:, grader:) }

    it "returns an Arm::Run over one linear user->assistant Timeline" do
      expect(run).to be_a(Lain::Arm::Run)
      expect(run.timeline.to_a.map(&:role)).to eq(%w[user assistant])
    end

    it "grades the run with the injected grader" do
      expect(run.grade).to be_a(Lain::Grader::Grade)
      expect(run.grade).to be_pass
    end

    it "records a non-negative wall-clock elapsed" do
      expect(run.elapsed).to be_a(Float).and be >= 0
    end

    it "produces a Run scored by Compare::Run.from_timeline" do
      allow(Lain::Compare::Run).to receive(:from_timeline).and_call_original

      compare_run = run.compare_run

      expect(Lain::Compare::Run).to have_received(:from_timeline)
        .with(hash_including(timeline: run.timeline, grade: run.grade))
      expect(compare_run).to be_a(Lain::Compare::Run)
      expect(compare_run.total_tokens).to eq(120)
      expect(compare_run.cost).to be > 0
    end
  end

  describe "the injected isolation seam" do
    # The REAL Lease, not a stand-in for one: the arm now reclaims on the settled
    # path and surrenders from its `ensure`, so the idempotent-loud contract --
    # the reclaim runs exactly once however many times release is called -- is
    # what keeps this to a single reclamation.
    it "acquires a lease and releases it exactly once, even though the control ignores its env" do
      released = []
      lease = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default, on_release: -> { released << :once })
      isolation = instance_double("isolation", acquire: lease)

      arm.run("please echo hi", spawn_seam:, grader:, isolation:)

      expect(isolation).to have_received(:acquire)
      expect(lease).to be_released
      expect(released).to eq([:once])
    end
  end
end
