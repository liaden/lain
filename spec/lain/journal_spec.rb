# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "lain/journal"
require "lain/event"

RSpec.describe Lain::Journal do
  let(:io) { StringIO.new }
  subject(:journal) { described_class.new(io: io, clock: -> { "T" }) }

  def lines
    io.string.each_line.map(&:chomp)
  end

  describe "#record" do
    it "writes one complete JSON object per line" do
      journal.record("type" => "turn", "digest" => "abc")
      journal.record("type" => "usage", "input_tokens" => 10)

      expect(lines.size).to eq(2)
      expect(JSON.parse(lines[0])).to include("type" => "turn", "digest" => "abc", "ts" => "T")
      expect(JSON.parse(lines[1])).to include("type" => "usage", "input_tokens" => 10)
    end

    it "serializes an event via its #to_journal" do
      journal.record(Lain::Event::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))

      expect(JSON.parse(lines.first)).to include(
        "type" => "tool_output", "tool_use_id" => "t1", "stream" => "stdout", "bytes" => "hi"
      )
    end

    it "returns self, so records chain" do
      expect(journal.record("a" => 1)).to be(journal)
    end

    it "stamps every record with a timestamp" do
      journal.record("type" => "x")
      expect(JSON.parse(lines.first)).to have_key("ts")
    end

    it "symbol keys and string keys land identically" do
      journal.record(type: "sym")
      expect(JSON.parse(lines.first)).to include("type" => "sym")
    end

    # The Journal's contract is losslessness. A burst must arrive as N lines, each
    # independently parseable -- this is the acceptance test the brief names.
    it "emits a burst where every line parses independently" do
      500.times { |i| journal.record("type" => "event", "seq" => i) }

      parsed = lines.map { |line| JSON.parse(line) }
      expect(parsed.size).to eq(500)
      expect(parsed.map { |record| record["seq"] }).to eq((0...500).to_a)
    end

    it "refuses to record once closed" do
      journal.close
      expect { journal.record("a" => 1) }.to raise_error(described_class::Closed)
    end
  end

  # Losslessness would be a lie if an unencodable value tore a line or vanished.
  # A serialization failure must still produce ONE parseable line.
  describe "a value JSON cannot encode" do
    it "records a parseable journal_error instead of a torn line" do
      unencodable = Object.new
      def unencodable.to_journal = { "type" => "bad", "blob" => BasicObject.new }

      journal.record(unencodable)

      record = JSON.parse(lines.first)
      expect(record["type"]).to eq("journal_error")
      expect(record).to have_key("error")
    end

    it "keeps the stream parseable line-by-line across a bad record" do
      bad = Object.new
      def bad.to_journal = { "loop" => {}.tap { |x| x["self"] = x } }

      journal.record("type" => "before")
      journal.record(bad)
      journal.record("type" => "after")

      expect { lines.each { |line| JSON.parse(line) } }.not_to raise_error
      expect(lines.size).to eq(3)
    end

    it "raises loudly on an entry that is neither a Hash nor #to_journal-able" do
      journal.record(42)
      expect(JSON.parse(lines.first)["type"]).to eq("journal_error")
    end
  end

  describe "synchronous writes" do
    it "puts the fd in sync mode so nothing sits in a buffer" do
      real_io = StringIO.new
      described_class.new(io: real_io)
      expect(real_io.sync).to be(true)
    end
  end

  describe "concurrent producers" do
    # Synchronous-under-a-mutex means a burst from many threads still yields
    # whole, uncorrupted lines -- never two records smeared onto one line.
    it "never interleaves two records on one line" do
      threads = Array.new(8) do |t|
        Thread.new { 100.times { |i| journal.record("thread" => t, "i" => i) } }
      end
      threads.each(&:join)

      parsed = lines.map { |line| JSON.parse(line) }
      expect(parsed.size).to eq(800)
      expect(parsed.map { |r| [r["thread"], r["i"]] }.uniq.size).to eq(800)
    end
  end

  describe "fd ownership" do
    it "does not close an injected IO it does not own" do
      journal.close
      expect(io).not_to be_closed
    end

    it "closes a file it opened itself" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "session.ndjson")
        owned = described_class.open(path)
        owned.record("type" => "x")
        owned.close
        # Reopening and reading proves the write landed and the fd is released.
        expect(File.read(path)).to include("\"type\":\"x\"")
      end
    end

    it "is idempotent on close" do
      journal.close
      expect { journal.close }.not_to raise_error
    end
  end

  describe ".open" do
    it "creates the session file and its parent directory" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "s.ndjson")
        journal = described_class.open(path)
        journal.record("type" => "hello")
        journal.close
        expect(File).to exist(path)
      end
    end
  end

  describe "#fileno" do
    it "is nil for a StringIO with no descriptor" do
      expect(journal.fileno).to be_nil
    end

    it "exposes the descriptor of a real file, for handing to Rust tracing" do
      Dir.mktmpdir do |dir|
        journal = described_class.open(File.join(dir, "s.ndjson"))
        expect(journal.fileno).to be_a(Integer)
        journal.close
      end
    end
  end
end
