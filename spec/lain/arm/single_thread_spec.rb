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

    # No "records a non-negative elapsed" example: elapsed is a delta off a
    # monotonic clock, so `Float` and `>= 0` are both true by construction and
    # neither can fail. "the injected instrument" below pins the number itself.
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

  # T24: elapsed and cost come off ONE injected instrument, shared by every arm,
  # so the two headline bench metrics cannot drift apart per topology.
  describe "the injected instrument" do
    it "takes elapsed off the instrument's own clock" do
      ticks = 0.0
      instrument = Lain::Arm::Instrument.new(clock: -> { ticks += 0.25 })

      run = described_class.new(instrument:).run("please echo hi", spawn_seam:, grader:)

      expect(run.elapsed).to eq(0.25)
    end

    it "prices the run through the instrument's own price book" do
      # Nothing in the map, so every model falls to a free fallback: what is
      # pinned is WHOSE book priced the run, not the rate.
      zero = Lain::Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      free = Lain::PriceBook.new(prices: {}, fallback: zero)
      arm = described_class.new(instrument: Lain::Arm::Instrument.new(price_book: free))

      run = arm.run("please echo hi", spawn_seam:, grader:)

      expect(run.total_tokens).to eq(120)
      expect(run.compare_run.cost).to eq(0)
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
      isolation = instance_double(Lain::Isolation::Null, acquire: lease)

      arm.run("please echo hi", spawn_seam:, grader:, isolation:)

      expect(isolation).to have_received(:acquire)
      expect(lease).to be_released
      expect(released).to eq([:once])
    end
  end
end
