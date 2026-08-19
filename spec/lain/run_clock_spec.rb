# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of T33's rule: the monotonic clock primitive is named
# ONCE in lib/, in run_clock.rb, as {Lain::RunClock::MONOTONIC}'s body. Every
# other timing seam takes that constant as its `clock:` default.
#
# Ripper, not grep, for the reason {OutputDiscipline} gives: `CLOCK_MONOTONIC`
# appears in prose (tty.rb's `@param clock` doc explains that `clock:` is
# monotonic while `wall_clock:` is not) and a text scan would count the
# sentence. Only a real constant REFERENCE counts.
#
# WHAT THIS DOES NOT CATCH, stated so the next reader does not over-trust it.
# It matches constant references only, so a second inline clock still slips
# through if it is written as `clock_gettime(1)` (the numeric clock id), or as
# an alias (`X = RunClock::MONOTONIC`, which is a second NAME but not a second
# reading). And it says nothing about a seam whose default is a *wall* clock:
# `clock: -> { Time.now.to_f }` names no primitive and passes. That last gap is
# the real one -- see the "no seam has a private clock" ticket in
# `.handback-T33.md`, which needs a positive census of the seams rather than
# this negative scan.
module MonotonicDiscipline
  # The primitive whose every reference is being centralized, matched as a
  # PREFIX so the coarse and raw variants (`CLOCK_MONOTONIC_COARSE`,
  # `CLOCK_MONOTONIC_RAW`) count too -- they are the same clock at a different
  # resolution, and a seam reaching for one is the same drift.
  PRIMITIVE = "CLOCK_MONOTONIC"

  # The one file allowed to name it, relative to `lib/`.
  HOME = "lain/run_clock.rb"

  module_function

  def lib_root = Pathname(__dir__).join("..", "..", "lib").expand_path

  # @return [Array<String>] "path:line" for every reference under `lib/`
  def sites
    lib_root.glob("**/*.rb").flat_map do |file|
      scan(file.relative_path_from(lib_root).to_s, file.read)
    end
  end

  def scan(path, source)
    sexp = Ripper.sexp(source)
    raise "could not parse #{path}" if sexp.nil?

    references(sexp).map { |node| "#{path}:#{node[2]&.first}" }
  end

  # A constant reference is `[:@const, "NAME", [line, column]]` wherever it
  # appears -- bare, as the right half of a `Process::CLOCK_MONOTONIC` scope
  # resolution, or as the Symbol argument to a `const_get`.
  def references(node)
    return [] unless node.is_a?(Array)

    here = node[0] == :@const && node[1].start_with?(PRIMITIVE) ? [node] : []
    here + node.flat_map { |child| references(child) }
  end
end

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
                                    bytes_before: 100, bytes_after: 10,
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

  # T33: this class was already the repo's clock object, so the shared default
  # lives here rather than in a new `Lain::Clock` unit -- a second clock name
  # would reproduce the very duplication this collects.
  describe "MONOTONIC" do
    it "answers monotonic seconds" do
      first = described_class::MONOTONIC.call
      second = described_class::MONOTONIC.call

      expect(first).to be_a(Float)
      expect(second).to be >= first
    end

    it "is ONE object, so two seams built on the default are equal rather than merely alike" do
      expect(Lain::Arm::Instrument.new.clock).to be(described_class::MONOTONIC)
      expect(Lain::Arm::Instrument.new).to eq(Lain::Arm::Instrument.new)
    end

    it "is the only place in lib/ that NAMES the monotonic clock primitive" do
      strays = MonotonicDiscipline.sites.reject { |site| site.start_with?("#{MonotonicDiscipline::HOME}:") }

      expect(strays).to be_empty, lambda {
        "#{MonotonicDiscipline::PRIMITIVE} is named once in lib/, as " \
          "Lain::RunClock::MONOTONIC's body; every other timing seam takes that " \
          "constant as its clock: default. Found:\n  #{strays.join("\n  ")}"
      }
    end

    it "is named once even inside run_clock.rb, so RunClock's own default reads the constant too" do
      expect(MonotonicDiscipline.sites).to contain_exactly(a_string_starting_with("#{MonotonicDiscipline::HOME}:"))
    end

    # Guards the guard: the scanner walks the syntax tree, so the sentence in
    # tty.rb's `@param clock` doc must not count as a reference.
    it "does not count the primitive in a comment or a string (self-test)" do
      source = <<~RUBY
        # clock: is Process::CLOCK_MONOTONIC, wall_clock: is not
        label = "Process::CLOCK_MONOTONIC"
      RUBY

      expect(MonotonicDiscipline.scan("self_test", source)).to be_empty
    end

    it "counts a real reference (self-test)" do
      source = "def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)\n"

      expect(MonotonicDiscipline.scan("self_test", source)).to eq(["self_test:1"])
    end

    it "counts the coarse and raw variants of the same clock (self-test)" do
      source = <<~RUBY
        a = Process.clock_gettime(Process::CLOCK_MONOTONIC_RAW)
        b = Process.clock_gettime(Process::CLOCK_MONOTONIC_COARSE)
        c = Process.clock_gettime(Process.const_get(:CLOCK_MONOTONIC))
      RUBY

      expect(MonotonicDiscipline.scan("self_test", source))
        .to eq(%w[self_test:1 self_test:2 self_test:3])
    end

    # The stated limits, pinned so the "what this does not catch" paragraph
    # cannot quietly become wrong: these two DO slip through, on purpose.
    it "is silent on the numeric clock id and on an alias (self-test, documented gap)" do
      source = <<~RUBY
        a = Process.clock_gettime(1)
        SECOND_NAME = Lain::RunClock::MONOTONIC
      RUBY

      expect(MonotonicDiscipline.scan("self_test", source)).to be_empty
    end
  end
end
