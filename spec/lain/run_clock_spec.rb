# frozen_string_literal: true

# RunClock derives three elapsed-time measures for the chat UI -- since
# session start, since the user last answered a prompt, since the last
# compaction -- each a subtraction against one injected clock, matching
# {Lain::CLI::Conductor}'s own monotonic `clock:` idiom. See its header for
# why that (and not StatusFeed's wall-clock deadline) is the right shape here.
RSpec.describe Lain::RunClock do
  # A settable clock, so an example can advance time without sleeping.
  def clock_at(start)
    now = start
    setter = ->(value) { now = value }
    [-> { now }, setter]
  end

  def compaction_event
    Lain::Telemetry::Compaction.new(trigger: %i[token_threshold], cache_state: :cold,
                                    tokens_before: 100, tokens_after: 10,
                                    cost_saved: nil, cost_spent: nil)
  end

  def spawn_event
    Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn", from: "parent", to: nil)
  end

  describe "#elapsed" do
    it "is measured from construction" do
      clock, set = clock_at(1000.0)
      run_clock = described_class.new(clock:)

      set.call(1090.0)

      expect(run_clock.elapsed).to eq(90.0)
    end
  end

  describe "#record_input and #idle" do
    it "resets the idle measure when the user answers a prompt" do
      clock, set = clock_at(1000.0)
      run_clock = described_class.new(clock:)
      set.call(1050.0)

      run_clock.record_input
      set.call(1080.0)

      expect(run_clock.idle).to eq(30.0)
    end

    it "reads idle as time since session start before any input is answered" do
      clock, set = clock_at(1000.0)
      run_clock = described_class.new(clock:)

      set.call(1015.0)

      expect(run_clock.idle).to eq(15.0)
    end
  end

  describe "#since_compaction" do
    it "is nil when no compaction has ever been observed -- absence, not zero" do
      run_clock = described_class.new(clock: -> { 1000.0 })

      expect(run_clock.since_compaction).to be_nil
    end

    it "reads elapsed time since a compaction event arrives off the channel" do
      clock, set = clock_at(1000.0)
      run_clock = described_class.new(clock:)

      run_clock << compaction_event
      set.call(1010.0)

      expect(run_clock.since_compaction).to eq(10.0)
    end
  end

  describe "#<<" do
    it "is inert for an unrelated event: nothing raises and no measure changes" do
      clock, set = clock_at(1000.0)
      run_clock = described_class.new(clock:)

      expect { run_clock << spawn_event }.not_to raise_error
      set.call(1010.0)

      expect(run_clock.since_compaction).to be_nil
    end

    it "returns self, matching the channel sink duck" do
      run_clock = described_class.new(clock: -> { 1000.0 })

      expect(run_clock << spawn_event).to be(run_clock)
    end
  end
end
