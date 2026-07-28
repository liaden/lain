# frozen_string_literal: true

# The chronicle stand-in {Lain::CLI::LiveViews} wraps its tee onto: the REAL
# {Lain::CLI::JournalTee} over a recording journal leg, so what a spec reads
# back is the fan-out the run actually builds, with only the NDJSON file
# swapped for an in-memory list. A double would have let the tee's shape drift.
class LiveViewsSpecChronicle
  attr_reader :journal

  def initialize = @journal = RecordingChannel.new

  def wrap_tee(sink) = Lain::CLI::JournalTee.new(@journal, sink)
end

# A live-view leg that is neither closed nor healthy: the tee's review probe
# (see {Lain::CLI::JournalTee}) established that ONE broken sink must not cost
# the sinks after it their event, and the tool-output fan-out inherits that.
class LiveViewsSpecBrokenChannel
  def push(_event) = raise(IOError, "sink is gone")
  alias << push
end

# A second, differently-broken leg -- so "every cause is named" is an
# assertion about the report, not a coincidence of one error class.
class LiveViewsSpecOtherBrokenChannel
  def push(_event) = raise("the other leg is gone too")
  alias << push
end

RSpec.describe Lain::CLI::LiveViews do
  let(:chronicle) { LiveViewsSpecChronicle.new }
  let(:status_feed) { RecordingChannel.new }
  # The run's live Channel -- what Frontend::TTY drains. Recording rather than
  # a real SizedQueue, because nothing here drains it.
  let(:tty) { RecordingChannel.new }
  let(:socket) { "/tmp/lain-live-views-spec.sock" }
  let(:attached) { described_class.new(options: { nvim: socket }, chronicle:, status_feed:) }
  let(:headless) { described_class.new(options: { journal: true }, chronicle:, status_feed:) }
  let(:hello) { Lain::Telemetry::ToolOutput.new(tool_use_id: "tu_1", stream: :stdout, bytes: "hello\n") }

  describe "#views" do
    it "hands the Repl the editor's Channel, its socket, and the tee'd journal" do
      views = attached.views

      expect(views[:channel]).to be_a(Lain::Channel::DropOldest)
      expect(views[:socket_path]).to eq(socket)
      expect(views[:journal]).to be(attached.journal)
    end

    it "is nil when no editor is attached" do
      expect(headless.views).to be_nil
    end
  end

  # T1. Streamed tool bytes are a VIEW, not a record: the durable copy already
  # rides the turn's tool_result (Tools::Bash.render_output), so this fan-out
  # reaches channels only and never the journal.
  describe ".tool_output" do
    # The escalation trigger the card names: Sink::IOAdapter#emit calls `push`,
    # and Channel aliases `<<` TO push, not the reverse -- a JournalTee dropped
    # in here would raise NoMethodError on the first byte of tool output.
    it "answers the producer's `push` duck, not only `<<`" do
      fan = described_class.tool_output(tty, attached.views)

      expect(fan).to respond_to(:push)
      expect(fan.push(hello)).to be(fan)
    end

    it "is the TTY Channel itself when no editor is attached, so a plain chat crosses nothing extra" do
      expect(described_class.tool_output(tty, headless.views)).to be(tty)
    end

    it "fans a streamed tool event onto the editor's Channel as well as the TTY's" do
      views = attached.views

      described_class.tool_output(tty, views).push(hello)

      expect(tty.events).to eq([hello])
      expect(views[:channel].drain).to eq([hello])
    end

    # AC1's rendered half: the very event that reached the editor's Channel is
    # what the append-only lain://journal buffer turns into text.
    it "reaches the lain://journal buffer as an attributed line" do
      views = attached.views

      described_class.tool_output(tty, views).push(hello)

      lines = views[:channel].drain.flat_map { |event| Lain::Frontend::Neovim::JournalView.new.lines(event) }
      expect(lines).to eq(["[tu_1 stdout] hello"])
    end

    # AC2: the durable record is unchanged. ToolOutput is Journalable (it would
    # serialize as "tool_output"), so nothing but the wiring keeps it off the
    # NDJSON -- which is exactly what this asserts.
    it "never puts streamed bytes on the durable record" do
      described_class.tool_output(tty, attached.views).push(hello)

      expect(chronicle.journal.events).to be_empty
      expect(status_feed.events).to be_empty
    end

    # AC3: quitting nvim closes its Channel (Frontend::Neovim's teardown
    # contract), and a dead viewer must never break a running tool.
    it "keeps the TTY leg landing after the editor quit and closed its Channel" do
      views = attached.views
      views[:channel].close

      expect { described_class.tool_output(tty, views).push(hello) }.not_to raise_error
      expect(tty.events).to eq([hello])
    end

    it "gives every channel its turn before a real failure surfaces" do
      fan = described_class::Fanout.new(LiveViewsSpecBrokenChannel.new, tty)

      expect { fan.push(hello) }.to raise_error(IOError, "sink is gone")
      expect(tty.events).to eq([hello])
    end

    # T1 review, Linus: a closed TTY leg is the one failure that must NOT be
    # swallowed. Swallowing it would make one failure have two behaviours
    # depending on an unrelated flag -- without --nvim the bare Channel raises
    # and Handler::Live's gate 3 turns it into an is_error tool_result, while
    # with --nvim the tool would report success though nobody saw the bytes.
    it "raises a closed TTY Channel's failure whether or not an editor is attached" do
      closed = Lain::Channel.new(capacity: 2).close

      expect { described_class.tool_output(closed, nil).push(hello) }.to raise_error(ClosedQueueError)
      expect { described_class.tool_output(closed, attached.views).push(hello) }.to raise_error(ClosedQueueError)
    end

    # The must-land distinction is about SWALLOWING, not about ordering: a
    # dying TTY leg still must not cost the editor its event.
    it "still reaches the editor when the TTY leg is the one that failed" do
      views = attached.views

      expect { described_class::Fanout.new(LiveViewsSpecBrokenChannel.new, views[:channel]).push(hello) }
        .to raise_error(IOError, "sink is gone")
      expect(views[:channel].drain).to eq([hello])
    end

    # T1 review, Jeremy Evans: raising only `failures.first` discards the other
    # causes, which is the exact loss {JournalTee::SinkFailures} was grown to
    # stop. The error class is reused rather than restated.
    it "names every failing leg, not just the first" do
      fan = described_class::Fanout.new(LiveViewsSpecBrokenChannel.new, LiveViewsSpecOtherBrokenChannel.new)

      expect { fan.push(hello) }.to raise_error(Lain::CLI::JournalTee::SinkFailures) { |error|
        expect(error.failures.map(&:message)).to eq(["sink is gone", "the other leg is gone too"])
        expect(error.message).to include("sink is gone", "the other leg is gone too")
      }
    end
  end
end
