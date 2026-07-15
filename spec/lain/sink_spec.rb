# frozen_string_literal: true

# A tiny in-memory stand-in for Lain::Channel: records everything pushed so we
# can assert on emitted events without depending on Channel's threading.
class RecordingChannel
  attr_reader :events

  def initialize
    @events = []
  end

  def push(event)
    @events << event
    self
  end
end

RSpec.describe Lain::Sink do
  describe Lain::Sink::IOAdapter do
    subject(:adapter) { described_class.new(channel, tool_use_id: "toolu_123", stream: :stdout) }

    let(:channel) { RecordingChannel.new }

    def emitted_bytes
      channel.events.map(&:bytes)
    end

    it "rejects an invalid stream at construction, not at first write" do
      expect { described_class.new(channel, tool_use_id: "t", stream: :stdin) }
        .to raise_error(ArgumentError, /stream must be one of/)
    end

    describe "#write" do
      it "emits one attributed ToolOutput and returns the byte count" do
        result = adapter.write("hello")

        expect(result).to eq(5)
        expect(channel.events.size).to eq(1)
        event = channel.events.first
        expect(event).to be_a(Lain::Telemetry::ToolOutput)
        expect(event.tool_use_id).to eq("toolu_123")
        expect(event.stream).to eq(:stdout)
        expect(event.bytes).to eq("hello")
      end

      it "concatenates multiple arguments and returns total bytes (multibyte aware)" do
        expect(adapter.write("ab", "cd")).to eq(4)
        expect(emitted_bytes).to eq(["abcd"])

        channel.events.clear
        expect(adapter.write("é")).to eq(2) # 2 bytes, 1 char
      end

      it "does not emit a zero-byte event" do
        expect(adapter.write("")).to eq(0)
        expect(channel.events).to be_empty
      end
    end

    describe "#puts (faithful IO semantics)" do
      it "writes a lone newline with no arguments" do
        expect(adapter.puts).to be_nil
        expect(emitted_bytes).to eq(["\n"])
      end

      it "turns nil into a newline" do
        adapter.puts(nil)
        expect(emitted_bytes).to eq(["\n"])
      end

      it "appends a newline unless the string already ends in one" do
        adapter.puts("foo")
        adapter.puts("bar\n")
        expect(emitted_bytes).to eq(%W[foo\n bar\n])
      end

      it "does not collapse an existing trailing blank line" do
        adapter.puts("a\n\n")
        expect(emitted_bytes).to eq(["a\n\n"])
      end

      it "writes each argument on its own line" do
        adapter.puts("foo", "bar")
        expect(emitted_bytes).to eq(["foo\nbar\n"])
      end

      it "flattens arrays recursively, and an empty array contributes nothing" do
        adapter.puts([1, 2, 3])
        adapter.puts([[1, 2], [3]])
        adapter.puts([])
        expect(emitted_bytes).to eq(%W[1\n2\n3\n 1\n2\n3\n]) # [] emitted nothing
      end
    end

    describe "#print / #<< / #flush" do
      it "#print writes each argument with no terminator and returns nil" do
        expect(adapter.print("a", "b")).to be_nil
        expect(emitted_bytes).to eq(["ab"])
      end

      it "emits exactly one event per #print call, N calls in a row -> N events (no hidden accumulation)" do
        5.times { |i| adapter.print("chunk#{i}") }

        expect(channel.events.size).to eq(5)
        expect(emitted_bytes).to eq(%w[chunk0 chunk1 chunk2 chunk3 chunk4])
        expect(channel.events).to all(have_attributes(tool_use_id: "toolu_123"))
      end

      it "#<< writes and returns self" do
        expect(adapter << "chunk").to be(adapter)
        expect(emitted_bytes).to eq(["chunk"])
      end

      it "#flush is a no-op returning self" do
        expect(adapter.flush).to be(adapter)
        expect(channel.events).to be_empty
      end
    end
  end

  describe Lain::Sink::Null do
    subject(:null) { described_class.new }

    it "#write swallows bytes but returns the count (IO contract)" do
      expect(null.write("hello", "!")).to eq(6)
    end

    it "#puts and #print return nil" do
      expect(null.puts("x")).to be_nil
      expect(null.print("x")).to be_nil
    end

    it "#<< and #flush return self" do
      expect(null << "x").to be(null)
      expect(null.flush).to be(null)
    end
  end
end
