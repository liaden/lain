# frozen_string_literal: true

require "stringio"

# T3: the Journal-duck decorator over {Lain::Provider::Admission}. The RECORD it
# emits is spec'd at its own mirror path, `spec/lain/telemetry/provider_wait_spec.rb`;
# what is asserted here is the DECORATION -- that a caller which queued is
# journaled, that one admitted on its first attempt is not, that a refusal is
# journaled as a refusal, and that `#enter`/`#try_enter` are wrapped without
# reaching past them.
RSpec.describe Lain::Provider::Admission::Journal do
  let(:endpoint) { "http://localhost:11434" }
  let(:poll_interval) { 0.005 }
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }

  # The first clock read happens only AFTER a caller's first `take_slot` has
  # failed -- see {Admission#wait_for_slot} -- so it is exactly the "this caller
  # is now queued" signal a spec needs to release the holder without sleeping on
  # a guess.
  let(:queued) { Queue.new }
  let(:clock) do
    lambda do
      queued.push(:queued) if queued.empty?
      Lain::RunClock::MONOTONIC.call
    end
  end

  let(:admission) do
    Lain::Provider::Admission.new(endpoint:, width: 1, deadline: 1.0, poll_interval:, clock:)
  end
  let(:decorator) { described_class.new(admission:, journal:) }

  # Holds the one slot until the returned lambda is called.
  def hold_the_slot
    inside = Queue.new
    finish = Queue.new
    thread = Thread.new { admission.enter { inside.push(:in) && finish.pop } }
    inside.pop
    [thread, -> { finish.push(:done) }]
  end

  describe "#enter" do
    it "journals a provider_wait naming the endpoint and the seconds waited" do
      holder, release = hold_the_slot
      seen = nil
      waiter = Thread.new { decorator.enter { |waited| seen = waited } }
      queued.pop
      release.call
      [waiter, holder].each { |thread| thread.join(5) }

      expect(seen).to be > 0
      expect(io).to include_journal_record("provider_wait", kind: "waited", endpoint:,
                                                            waited_seconds: seen.round(3))
    end

    it "records the resolution the wait was quantised at, so nobody reads it as a measurement" do
      holder, release = hold_the_slot
      waiter = Thread.new { decorator.enter { :done } }
      queued.pop
      release.call
      [waiter, holder].each { |thread| thread.join(5) }

      expect(io).to include_journal_record("provider_wait", resolution_seconds: poll_interval)
    end

    it "journals nothing when the caller took a slot on its first attempt" do
      decorator.enter { :done }

      expect(io.string).to be_empty
    end

    it "returns the block's value and hands the block the wait it was told" do
      seen = nil
      value = decorator.enter { |waited| seen = waited and :value }

      expect(value).to eq(:value)
      expect(seen).to eq(Lain::Provider::Admission::NO_WAIT)
    end

    it "releases the slot, so the decorator is not a leak the admission cannot see" do
      decorator.enter { :done }

      expect(decorator.in_flight).to eq(0)
    end
  end

  describe "a wait refused at the deadline" do
    let(:admission) do
      Lain::Provider::Admission.new(endpoint:, width: 1, deadline: 0.05, poll_interval:, clock:)
    end

    it "re-raises Busy unchanged" do
      holder, release = hold_the_slot

      expect { decorator.enter { :never } }.to raise_error(Lain::Provider::Admission::Busy, /is busy/)

      release.call
      holder.join(5)
    end

    it "journals the refusal rather than a completed wait" do
      holder, release = hold_the_slot
      begin
        decorator.enter { :never }
      rescue Lain::Provider::Admission::Busy
        nil
      end
      release.call
      holder.join(5)

      expect(io).to include_journal_record("provider_wait", kind: "refused", endpoint:,
                                                            waited_seconds: nil)
    end
  end

  describe "#try_enter" do
    it "forwards to the wrapped admission and journals nothing -- a skip is not a wait" do
      expect(decorator.try_enter { :done }).to eq(:done)
      expect(io.string).to be_empty
    end

    it "answers REFUSED without journaling when the endpoint is busy" do
      holder, release = hold_the_slot

      expect(decorator.try_enter { :never }).to eq(Lain::Provider::Admission::REFUSED)
      expect(io.string).to be_empty

      release.call
      holder.join(5)
    end
  end

  describe "the duck it presents" do
    it "answers the endpoint, width, deadline and in-flight count of the admission it wraps" do
      expect(decorator).to have_attributes(endpoint:, width: 1, deadline: 1.0, in_flight: 0)
    end

    it "wraps the Null arm without ever journaling, because an ungated caller never queues" do
      null = described_class.new(admission: Lain::Provider::Admission::Null.new(endpoint:), journal:)

      expect(null.enter { :done }).to eq(:done)
      expect(null.width).to eq(Float::INFINITY)
      expect(io.string).to be_empty
    end
  end

  # Fix 1. `Busy` is not the gate's private exception: an inner admission for a
  # DIFFERENT endpoint raises the same class, so a bare `rescue Busy` cannot tell
  # "the gate refused me" from "the work I was admitted to do refused". These two
  # fail differently -- the first invents a refusal for a caller the gate let in,
  # the second emits BOTH a wait and a refusal for one call -- so both are pinned.
  describe "a Busy raised by the admitted block, not by the gate" do
    it "journals nothing when the gate admitted the caller straight away" do
      expect { decorator.enter { raise Lain::Provider::Admission::Busy, "inner endpoint is busy" } }
        .to raise_error(Lain::Provider::Admission::Busy, "inner endpoint is busy")

      expect(io.string).to be_empty
    end

    it "journals the wait alone, never a wait and a refusal for one call" do
      holder, release = hold_the_slot
      waiter = Thread.new do
        decorator.enter { raise Lain::Provider::Admission::Busy, "inner endpoint is busy" }
      rescue Lain::Provider::Admission::Busy
        :swallowed
      end
      queued.pop
      release.call
      [waiter, holder].each { |thread| thread.join(5) }

      kinds = Lain::Journal.records(io.string.lines, type: "provider_wait").to_a.map { |r| r["kind"] }
      expect(kinds).to eq(["waited"])
    end
  end

  describe "the resolution it reports" do
    # Fix 2. Taken from the admission being wrapped rather than defaulted, so a
    # gate built with a non-default poll interval cannot be described by a figure
    # it does not run at.
    let(:poll_interval) { 0.02 }

    it "is the wrapped admission's own poll interval, not a default" do
      holder, release = hold_the_slot
      waiter = Thread.new { decorator.enter { :done } }
      queued.pop
      release.call
      [waiter, holder].each { |thread| thread.join(5) }

      expect(decorator.resolution_seconds).to eq(0.02)
      expect(io).to include_journal_record("provider_wait", resolution_seconds: 0.02)
    end
  end

  # T2 made {Admission.for} canonicalise before it builds, so one server has one
  # gate whatever spelling reached it -- and `#endpoint` therefore reports the
  # CANONICAL form. That silently changes what this decorator's records name, so
  # it is pinned rather than left to be discovered from a report that groups
  # oddly. It is the behaviour we want: `endpoint` is the key a report sums a
  # server's waits over, and two spellings of one ollama must not become two rows.
  describe "the endpoint its records name, against a canonicalising gate" do
    after { Lain::Provider::Admission.reset! }

    it "names the canonical server, not the spelling the caller used" do
      Lain::Provider::Admission.reset!
      spelling = "http://127.0.0.1:11434"
      gate = Lain::Provider::Admission.for(endpoint: spelling)
      decorated = described_class.new(admission: gate, journal:)

      inside = Queue.new
      finish = Queue.new
      holder = Thread.new { gate.enter { inside.push(:in) && finish.pop } }
      inside.pop
      waiter = Thread.new { decorated.enter { :done } }
      sleep gate.poll_interval * 2
      finish.push(:done)
      [waiter, holder].each { |thread| thread.join(5) }

      expect(decorated.endpoint).to eq("http://localhost:11434")
      expect(io).to include_journal_record("provider_wait", endpoint: "http://localhost:11434")
      expect(io.string).not_to include(spelling)
    end
  end

  it "writes a journal every reader can parse" do
    holder, release = hold_the_slot
    waiter = Thread.new { decorator.enter { :done } }
    queued.pop
    release.call
    [waiter, holder].each { |thread| thread.join(5) }

    expect(io).to be_valid_ndjson
  end
end
