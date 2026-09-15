# frozen_string_literal: true

require "stringio"

# JournalTee fans one event onto the durable Journal record and any number of
# live-view sinks -- the frontend's Channel, {Lain::StatusFeed}, ... --
# extracted from exe/lain (see Lain::CLI::Backend's precedent) so it carries a
# spec the way lib/ does. Generalized from a fixed journal+channel pair to
# 1->N sinks once StatusFeed needed the same fan-out with the same swallow
# discipline.
#
# A live-view sink is the one that dies: quitting nvim closes its
# Channel::DropOldest (Frontend::Neovim's own contract -- see
# spec/lain/frontend/neovim_spec.rb's "teardown under editor death" examples,
# which this class must not change). A closed sink's `<<` raises
# ClosedQueueError, and that used to escape through Accounting#observe and kill
# the whole chat. The journal leg must always land; only a closed SINK is
# survivable, and only via ClosedQueueError -- nothing else is swallowed, no
# matter how many sinks are wired in.
RSpec.describe Lain::CLI::JournalTee do
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:, clock: -> { "T" }) }

  def journal_lines
    io.string.each_line.map(&:chomp)
  end

  # Under `--no-journal --nvim` the tee IS the run's record journal, and the
  # mode switch, the policy switch and the goal driver all write `#record`.
  it "answers #record exactly as it answers <<, so it can stand where a Journal does" do
    channel = Lain::Channel::DropOldest.new
    tee = described_class.new(journal, channel)

    expect(tee.record({ "type" => "mode_switch" })).to be(tee)
    expect(JSON.parse(journal_lines.first)).to include("type" => "mode_switch")
    expect(channel.size).to eq(1)
  end

  # And the batch spelling a session scribe writes a retreat and its
  # replacement through: one durable write, then each record to every sink.
  it "answers #record_all with one journal write, then tells every sink each record" do
    channel = Lain::Channel::DropOldest.new
    tee = described_class.new(journal, channel)
    writes = []
    allow(io).to(receive(:write).and_wrap_original { |original, bytes| writes << bytes and original.call(bytes) })

    expect(tee.record_all([{ "type" => "rewound" }, { "type" => "turn" }])).to be(tee)

    expect(writes.size).to eq(1)
    expect(journal_lines.map { |line| JSON.parse(line)["type"] }).to eq(%w[rewound turn])
    expect(channel.size).to eq(2)
  end

  it "survives a dead channel: the journal receives the record and no error escapes" do
    channel = Lain::Channel::DropOldest.new
    channel.close
    tee = described_class.new(journal, channel)

    expect { tee << { "type" => "turn_usage" } }.not_to raise_error
    expect(journal_lines.size).to eq(1)
    expect(JSON.parse(journal_lines.first)).to include("type" => "turn_usage")
  end

  it "writes the journal leg first: a channel whose << raises ClosedQueueError still leaves the record journaled" do
    channel = instance_double(Lain::Channel::DropOldest)
    allow(channel).to receive(:<<).and_raise(ClosedQueueError)
    tee = described_class.new(journal, channel)

    tee << { "type" => "turn_usage" }

    expect(journal_lines.size).to eq(1)
    expect(JSON.parse(journal_lines.first)).to include("type" => "turn_usage")
  end

  # Also the "no consumer, no cost" AC: a caller that wires exactly what it
  # always wired (journal, channel) sees byte-identical behavior -- the N-sink
  # generalization is additive, never a behavior change for the 2-sink case.
  it "delivers to both legs while both are open" do
    channel = Lain::Channel::DropOldest.new
    tee = described_class.new(journal, channel)

    tee << { "type" => "turn_usage" }

    expect(journal_lines.size).to eq(1)
    expect(channel.size).to eq(1)
  end

  it "returns self, so events chain the same way a Journal or Channel does" do
    channel = Lain::Channel::DropOldest.new
    tee = described_class.new(journal, channel)

    expect(tee << { "type" => "turn_usage" }).to be(tee)
  end

  # Escalation guard, not an AC: only ClosedQueueError from the channel leg is
  # swallowed. Anything else is a real bug and must propagate.
  it "does not swallow errors other than ClosedQueueError from the channel leg" do
    channel = instance_double(Lain::Channel::DropOldest)
    allow(channel).to receive(:<<).and_raise(ArgumentError, "boom")
    tee = described_class.new(journal, channel)

    expect { tee << { "type" => "turn_usage" } }.to raise_error(ArgumentError, "boom")
  end

  # AC: the tee fans out.
  describe "fanning out to N sinks" do
    let(:channel) { Lain::Channel::DropOldest.new }
    let(:status_feed) { instance_double(Lain::StatusFeed) }

    it "delivers one event to the journal and every additional sink" do
      allow(status_feed).to receive(:<<)
      tee = described_class.new(journal, channel, status_feed)

      tee << { "type" => "turn_usage" }

      expect(journal_lines.size).to eq(1)
      expect(channel.size).to eq(1)
      expect(status_feed).to have_received(:<<).with({ "type" => "turn_usage" })
    end

    it "writes durably to the journal before any fan-out sink sees the event" do
      call_order = []
      allow(journal).to receive(:<<).and_wrap_original do |original, event|
        call_order << :journal
        original.call(event)
      end
      allow(status_feed).to receive(:<<) { call_order << :status_feed }
      tee = described_class.new(journal, channel, status_feed)

      tee << { "type" => "turn_usage" }

      expect(call_order.first).to eq(:journal)
      expect(call_order).to include(:status_feed)
    end

    it "a closed sink never breaks the others: a closed channel still leaves the status feed fed" do
      channel.close
      allow(status_feed).to receive(:<<)
      tee = described_class.new(journal, channel, status_feed)

      expect { tee << { "type" => "turn_usage" } }.not_to raise_error
      expect(journal_lines.size).to eq(1)
      expect(status_feed).to have_received(:<<)
    end

    it "a closed sink earlier in the list never breaks a later sink" do
      first_status_feed = instance_double(Lain::StatusFeed)
      allow(first_status_feed).to receive(:<<).and_raise(ClosedQueueError)
      second_channel = Lain::Channel::DropOldest.new
      tee = described_class.new(journal, first_status_feed, second_channel)

      expect { tee << { "type" => "turn_usage" } }.not_to raise_error
      expect(second_channel.size).to eq(1)
    end

    # AC: a raising sink is loud, not lost.
    it "surfaces a raising status-feed leg loudly, after the journal and channel legs already completed" do
      allow(status_feed).to receive(:<<).and_raise(Errno::ENOSPC)
      tee = described_class.new(journal, channel, status_feed)

      expect { tee << { "type" => "turn_usage" } }.to raise_error(Errno::ENOSPC)

      expect(journal_lines.size).to eq(1)
      expect(channel.size).to eq(1)
    end

    it "keeps the swallow-set exactly ClosedQueueError across every sink, not just the first" do
      allow(status_feed).to receive(:<<).and_raise(ClosedQueueError)
      channel.close
      tee = described_class.new(journal, channel, status_feed)

      expect { tee << { "type" => "turn_usage" } }.not_to raise_error
      expect(journal_lines.size).to eq(1)
    end
  end

  # The first N-sink cut's `@sinks.each { tell }` let a
  # non-ClosedQueueError raise from an EARLY sink abort the `each`, so every
  # sink positioned AFTER the raiser silently never saw the event -- even a
  # Channel, the exact leg the acceptance criterion names as one that "still
  # completes". Two review probes (journal_tee_raise_ordering_probe_spec.rb,
  # journal_tee_channel_after_raise_probe_spec.rb) demonstrated it; converted
  # here into permanent specs pinning the FIXED behavior: every sink is
  # attempted regardless of where a raiser sits, and sink order no longer
  # decides who receives an event.
  describe "sink order does not affect delivery" do
    it "a sink positioned AFTER a raising sink still receives the event" do
      early_channel = Lain::Channel::DropOldest.new
      raising_sink = instance_double(Lain::StatusFeed)
      allow(raising_sink).to receive(:<<).and_raise(Errno::ENOSPC)
      late_channel = Lain::Channel::DropOldest.new
      tee = described_class.new(journal, early_channel, raising_sink, late_channel)

      expect { tee << { "type" => "turn_usage" } }.to raise_error(Errno::ENOSPC)

      expect(early_channel.size).to eq(1)
      expect(late_channel.size).to eq(1) # FIXED: used to be 0, starved by the raise ahead of it
    end

    it "the Channel leg specifically still completes even when listed after a raising status feed" do
      raising_status_feed = instance_double(Lain::StatusFeed)
      allow(raising_status_feed).to receive(:<<).and_raise(Errno::ENOSPC)
      channel = Lain::Channel::DropOldest.new
      tee = described_class.new(journal, raising_status_feed, channel)

      expect { tee << { "type" => "turn_usage" } }.to raise_error(Errno::ENOSPC)

      expect(journal_lines.size).to eq(1)
      expect(channel.size).to eq(1) # FIXED: journal and channel legs still complete
    end
  end

  # The durable leg landing is what commits a flip written through this tee, so
  # a caller has to be able to tell "the record is on disk and a live view
  # failed" from "the record never landed" -- without inspecting journals.
  describe "telling a live sink's failure from the durable write's" do
    it "marks a single live sink's failure as recorded, keeping its own class and message" do
      raiser = instance_double(Lain::StatusFeed)
      allow(raiser).to receive(:<<).and_raise(ArgumentError, "boom")
      tee = described_class.new(journal, raiser)

      expect { tee.record({ "type" => "mode_switch" }) }.to raise_error(ArgumentError, "boom") { |error|
        expect(error).to be_a(described_class::Recorded)
      }
      expect(journal_lines.size).to eq(1)
    end

    # A frozen error cannot be extended, and a FrozenError out of the marking
    # would read as a durable failure: the half-apply this marker exists to end.
    it "marks a FROZEN live sink's failure as recorded, keeping its class, message and cause" do
      frozen = IOError.new("state feed gone").freeze
      raiser = Object.new
      raiser.define_singleton_method(:<<) { |_event| raise frozen }

      expect { described_class.new(journal, raiser) << { "type" => "mode_switch" } }
        .to raise_error(IOError, "state feed gone") { |error|
          expect(error).to be_a(described_class::Recorded)
          expect(error.cause).to eq(frozen.cause)
          expect(error.backtrace).not_to be_empty
        }
      expect(journal_lines.size).to eq(1)
    end

    it "marks several live sinks' failures as recorded too" do
      raisers = Array.new(2) { instance_double(Lain::StatusFeed).tap { |sink| allow(sink).to receive(:<<).and_raise(IOError) } }
      tee = described_class.new(journal, *raisers)

      expect { tee << { "type" => "mode_switch" } }
        .to raise_error(described_class::SinkFailures) { |error| expect(error).to be_a(described_class::Recorded) }
    end

    it "does not mark a durable write that failed, and tells no sink" do
      channel = Lain::Channel::DropOldest.new
      journal.close
      tee = described_class.new(journal, channel)

      expect { tee << { "type" => "mode_switch" } }
        .to raise_error(Lain::Journal::Closed) { |error| expect(error).not_to be_a(described_class::Recorded) }
      expect(channel.size).to eq(0)
    end

    it "answers a recorded failure from .landed, nil for a clean write, and lets any other raise through" do
      raiser = instance_double(Lain::StatusFeed)
      allow(raiser).to receive(:<<).and_raise(IOError, "feed")

      expect(described_class.landed { described_class.new(journal, raiser) << { "type" => "x" } }).to be_a(IOError)
      expect(described_class.landed { described_class.new(journal) << { "type" => "x" } }).to be_nil
      expect { described_class.landed { raise TypeError } }.to raise_error(TypeError)
    end
  end

  # More than one sink can fail on the same event now that every sink
  # is attempted unconditionally; the tee must not silently keep only the
  # first failure.
  describe "multiple sinks raising on the same event" do
    it "raises a SinkFailures naming every failure, and every non-raising sink still received the event" do
      first_raiser = instance_double(Lain::StatusFeed)
      allow(first_raiser).to receive(:<<).and_raise(ArgumentError, "first boom")
      good_channel = Lain::Channel::DropOldest.new
      second_raiser = instance_double(Lain::StatusFeed)
      allow(second_raiser).to receive(:<<).and_raise(TypeError, "second boom")
      tee = described_class.new(journal, first_raiser, good_channel, second_raiser)

      expect { tee << { "type" => "turn_usage" } }.to raise_error(Lain::CLI::JournalTee::SinkFailures) do |error|
        expect(error.failures.map(&:class)).to eq([ArgumentError, TypeError])
        expect(error.message).to include("first boom").and include("second boom")
      end
      expect(journal_lines.size).to eq(1)
      expect(good_channel.size).to eq(1)
    end

    it "a single failing sink among several raises ITS OWN error unwrapped, not SinkFailures" do
      good_channel = Lain::Channel::DropOldest.new
      raiser = instance_double(Lain::StatusFeed)
      allow(raiser).to receive(:<<).and_raise(ArgumentError, "boom")
      tee = described_class.new(journal, good_channel, raiser)

      expect { tee << { "type" => "turn_usage" } }.to raise_error(ArgumentError, "boom")
    end
  end
end
