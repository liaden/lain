# frozen_string_literal: true

require "rspec/core/sandbox"

RSpec.describe SpecWatchdog::Sentry do
  # The reader returns cumulative stall seconds, so the first read (watch start) is 0 and every later one is `stalled`.
  def starvation(stalled:, load1: 0.1)
    reads = 0
    SpecWatchdog::Sentry::Starvation.new(cores: 4, cpu_clock: -> { 0.0 }, load1_reader: -> { load1 },
                                         memory_reader: -> { (reads += 1) == 1 ? 0.0 : stalled })
  end

  # Runs one example inside a sandboxed RSpec, so its pending or failed outcome is observable without
  # touching this example's own result.
  def outcome(sentry:, **metadata)
    result = nil
    RSpec::Core::Sandbox.sandboxed do |config|
      group = RSpec.describe("overrunning") do
        around { |example| sentry.watch(example) { example.run } }

        it("sleeps", **metadata) { expect(sleep(5)).to be_positive }
      end
      group.run(RSpec::Core::Reporter.new(config))
      result = group.examples.sole.execution_result
    end
    result
  end

  def sentry(**starved)
    described_class.new(budget: 0.05, tick: 0.01, starvation: starvation(**starved))
  end

  describe SpecWatchdog::Sentry::Starvation do
    subject(:reading) { starvation(stalled: 0.0).reading(cpu_elapsed: 0.0, wall_elapsed: 30.0, memory_elapsed:) }

    context "when tasks stalled on memory for 20% or more of the window, on a box with no CPU load" do
      # A stall that ended 20s before the strike: a 10 second average would read near 0 by now.
      let(:memory_elapsed) { 6.0 }

      it "reads as starved, naming the memory pressure" do
        sentry = SpecWatchdog::Sentry.new(budget: 1, starvation: starvation(stalled: 0.0))

        expect(reading.starved).to be(true)
        expect(sentry.send(:starved_line, reading)).to include("memory pressure")
      end
    end

    context "when tasks stalled on memory for less than 20% of the window" do
      let(:memory_elapsed) { 5.9 }

      it("does not read as starved") { expect(reading.starved).to be(false) }
    end

    context "when the pressure file cannot be read" do
      let(:memory_elapsed) { 0.0 }
      let(:unreadable) do
        described_class.new(cores: 4, cpu_clock: -> { 0.0 }, load1_reader: -> { 0.1 },
                            memory_reader: -> { raise Errno::ENOENT })
      end

      it "reads the window as no stall, and not starved" do
        expect(unreadable.memory_now).to eq(0.0)
        expect(reading.starved).to be(false)
      end
    end

    it "reads the some total of the kernel's own file by default, in seconds" do
      expect(described_class.new.memory_now).to be_a(Float)
    end

    it "is not starved by memory stalls while the process had CPU" do
      busy = described_class.new(cores: 4, cpu_clock: -> { 0.0 }, load1_reader: -> { 0.1 }, memory_reader: -> { 0.0 })

      expect(busy.reading(cpu_elapsed: 30.0, wall_elapsed: 30.0, memory_elapsed: 30.0).starved).to be(false)
    end
  end

  describe "an overrun" do
    let(:starved) { { stalled: 1.0 } }
    let(:quiet) { { stalled: 0.0 } }

    it "ends a starvable example as pending with the STARVED line and the reason, not red" do
      result = outcome(sentry: sentry(**starved), starvable: "sandboxed build is slow when starved")

      expect(result.status).to eq(:pending)
      expect(result.pending_message).to include("STARVED", "memory pressure", "sandboxed build is slow when starved")
    end

    it "fails a starvable example with the STUCK line when the box is quiet" do
      result = outcome(sentry: sentry(**quiet), starvable: "sandboxed build is slow when starved")

      expect([result.status, result.exception.message]).to match([:failed, a_string_including("STUCK")])
    end

    it "fails an example that is not starvable even when the box is starved" do
      result = outcome(sentry: sentry(**starved))

      expect([result.status, result.exception.message]).to match([:failed, a_string_including("STUCK")])
    end

    it "judges a starvable example against its own budget when that is the larger" do
      result = outcome(sentry: sentry(**quiet), starvable: "slow", budget: 1)

      expect(result.exception.message).to include("against a 1s budget")
    end

    it "still ends the example with STUCK when building the report raises" do
      reads = 0
      broken = SpecWatchdog::Sentry::Starvation.new(cores: 4, cpu_clock: -> { 0.0 }, load1_reader: -> { 0.1 },
                                                    memory_reader: -> { (reads += 1) == 1 ? 0.0 : raise("boom") })
      result = outcome(sentry: described_class.new(budget: 0.05, tick: 0.01, starvation: broken))

      expect([result.status, result.exception&.message]).to match([:failed, a_string_including("STUCK", "boom")])
    end

    it "never lowers the operator's budget for a starvable example" do
      operator = described_class.new(budget: 1, tick: 0.01, starvation: starvation(**quiet))
      result = outcome(sentry: operator, starvable: "slow", budget: 0.05)

      expect(result.exception.message).to include("against a 1s budget")
    end
  end

  describe "the workspace profile's sandboxed examples" do
    let(:examples) do
      found = []
      RSpec::Core::Sandbox.sandboxed do
        load File.expand_path("lain/seams/workspace_profile_spec.rb", __dir__)
        found = RSpec.world.all_examples.map(&:metadata)
      end
      found.select { _1[:description].start_with?("passes") }
    end

    it "are starvable, each with a reason and its own budget" do
      expect(examples.size).to eq(2)
      expect(examples).to all(include(starvable: a_kind_of(String), budget: 60))
    end
  end
end
