# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

RSpec.describe Lain::Journal do
  subject(:journal) { described_class.new(io:, clock: -> { "T" }) }

  let(:io) { StringIO.new }

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
      journal.record(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))

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

    # Default journal placement is Paths' concern now -- Journal just asks for
    # sessions_dir and appends its timestamp+pid naming.
    it "lands its default path under Paths' XDG state sessions_dir when no path is given" do
      Dir.mktmpdir do |tmp|
        paths = Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => tmp })

        journal = described_class.open(paths:)
        journal.record("type" => "hello")
        journal.close

        expect(Dir.glob(File.join(paths.sessions_dir, "*.ndjson")).size).to eq(1)
      end
    end
  end

  # T3: .open creates the file, but the session header lands much later
  # (SessionRecord::Scribe writes it), so a chat that died in the window
  # between left a zero-byte .ndjson on disk FOREVER -- and it sorts newest,
  # so every reader that picks "the newest session" trips over it. The writer
  # cleans up after itself rather than leaving three readers to recognise the
  # artifact.
  describe "a session file nothing was ever recorded into" do
    it "leaves no zero-byte file behind on close" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.ndjson")

        described_class.open(path).close

        expect(File).not_to exist(path)
      end
    end

    it "keeps the file once a single record has landed" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.ndjson")
        journal = described_class.open(path)

        journal.record("type" => "session")
        journal.close

        expect(File).to exist(path)
      end
    end

    # Salvage reopens a CRASHED session's own file and may append nothing at
    # all (an already-recovered head). Unlinking on "we wrote nothing" would
    # destroy that record; the test is the file's own bytes, not ours.
    it "keeps an existing non-empty file it appended nothing to" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.ndjson")
        File.write(path, %({"type":"session"}\n))

        described_class.open(path).close

        expect(File.read(path)).to include("session")
      end
    end

    # The fd can be shared with the Rust tracing subscriber, which dups it and
    # writes spans we never see. Zero-byte means the FILE is empty, not that
    # this Journal happened not to write.
    it "keeps a file another writer on the shared fd landed bytes in" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.ndjson")
        journal = described_class.open(path)
        File.open(path, "ab") { |other| other.write("{\"subject\":\"rust\"}\n") }

        journal.close

        expect(File).to exist(path)
      end
    end

    it "never unlinks anything for an injected IO -- a file we did not open is not ours to remove" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.ndjson")
        File.write(path, "")

        File.open(path, "ab") { |io| described_class.new(io:).close }

        expect(File).to exist(path)
      end
    end
  end

  # The unlink is the only destructive filesystem operation the harness
  # performs on the experiment record, so it is pinned to the INODE this
  # Journal created rather than to the name it used. These are the reviewer's
  # `.review-T3/probe_unlink.rb` reproductions, ported: every one of them is a
  # file the Journal must NOT remove.
  describe "the unlink is pinned to the inode it created, never to the path" do
    around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

    def path_for(name) = File.join(@dir, name)

    # P2. Reachable today: Resume::Salvager reopens a crashed session's file,
    # which it did not create. A zero-byte one is somebody else's empty file,
    # not ours to clean up.
    it "keeps a zero-byte file that already existed when it opened" do
      path = path_for("p2.ndjson")
      File.write(path, "")

      described_class.open(path).close

      expect(File).to exist(path)
    end

    # Probe G. `path:` is a public kwarg on a public constructor, so "a file we
    # did not open is never ours to unlink" cannot rest on .open being its only
    # caller -- the doc says it, so the code has to enforce it.
    it "keeps the caller's file when the IO was injected, however the path was passed (G)" do
      path = path_for("g.ndjson")
      File.write(path, "")

      File.open(path, "ab") { |io| described_class.new(io:, path:, owns_io: false).close }

      expect(File).to exist(path)
    end

    # P3. #share_fd exists precisely so the Rust tracing subscriber can dup the
    # descriptor (ext/lain's dup_writer) and interleave its spans. Once the
    # number is handed out, another writer may land bytes after our close --
    # onto an unlinked inode, invisibly, if we still removed the file.
    it "keeps a file whose descriptor was handed to another writer through #share_fd" do
      path = path_for("p3.ndjson")
      journal = described_class.open(path)
      # A real dup(2), which is what ext/lain's dup_writer does. `autoclose:
      # false` on the wrapper because that fd belongs to the Journal -- letting
      # GC close it would yank a descriptor out from under another example.
      dup = IO.for_fd(journal.share_fd, autoclose: false).dup
      dup.sync = true

      journal.close
      dup.write(%({"type":"rust_span"}\n))
      dup.close

      expect(File).to exist(path)
      expect(File.read(path)).to include("rust_span")
    end

    # #fileno stays conservative: a descriptor that leaves the object may be
    # written through whatever the caller meant by asking, so the disarm must
    # not be something a caller has to remember to opt into.
    it "keeps a file whose descriptor merely left through #fileno too" do
      path = path_for("p3b.ndjson")
      journal = described_class.open(path)

      journal.fileno
      journal.close

      expect(File).to exist(path)
    end

    # P4. The comment this replaces reasoned only about a rename AWAY from the
    # path. A rename ONTO it substitutes a different inode under the same name.
    it "keeps a different file renamed onto the path between open and close" do
      path = path_for("p4.ndjson")
      journal = described_class.open(path)
      other = path_for("p4-other")
      File.write(other, "")
      File.rename(other, path)

      journal.close

      expect(File).to exist(path)
    end

    # P5. File.size? follows a symlink while unlink removes the link itself --
    # testing one file and deleting another. O_EXCL refuses to create through a
    # symlink at all, so the split cannot arise.
    it "keeps both the link and its target when the path is a symlink" do
      target = path_for("p5-target.ndjson")
      link = path_for("p5-link.ndjson")
      File.write(target, "")
      File.symlink(target, link)

      described_class.open(link).close

      expect(File).to exist(target)
      expect(File).to be_symlink(link)
    end

    # P6. THE one that decides it. Chronicle and ChatLaunch both document two
    # Journal.open calls straddling a clock tick as a bug that already had to
    # be closed once; when it cost a duplicate file that was untidy, and if the
    # empty one could unlink the live one's file it would cost a SESSION -- its
    # header and every turn landing on an inode with no name.
    it "never unlinks the file a second, live Journal on the same path is writing" do
      path = path_for("p6.ndjson")
      live = described_class.open(path)
      scratch = described_class.open(path)

      scratch.close
      live.record("type" => "session", "id" => "important")
      live.close

      expect(File).to exist(path)
      expect(File.read(path)).to include("important")
    end
  end

  # The one predicate the three readers (Resume::Selector, CLI::Watch,
  # CLI::Sessions) share for "this file holds no records at all".
  describe ".empty?" do
    it "is true for a zero-byte journal" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.ndjson")
        File.write(path, "")

        expect(described_class).to be_empty(path)
      end
    end

    it "is false for a file with bytes, even unparseable ones" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.ndjson")
        File.write(path, "not json at all\n")

        expect(described_class).not_to be_empty(path)
      end
    end

    # A file that vanished between a listing and this read has nothing to
    # offer a reader either -- a refusal, never a raw Errno::ENOENT.
    it "is true for a path that does not exist" do
      Dir.mktmpdir { |dir| expect(described_class).to be_empty(File.join(dir, "gone.ndjson")) }
    end
  end

  describe ".default_path" do
    it "is <sessions_dir>/<UTC-timestamp>-<pid>.ndjson" do
      Dir.mktmpdir do |tmp|
        paths = Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => tmp })

        path = described_class.default_path(paths:)

        expect(File.dirname(path)).to eq(paths.sessions_dir)
        expect(File.basename(path)).to match(/\A\d{8}T\d{6}-#{Process.pid}\.ndjson\z/)
      end
    end
  end

  describe "fsync mode" do
    it "invokes IO#fsync after the write when fsync: true" do
      file_io = instance_double(File, write: nil, "sync=": nil, fsync: nil)
      journal = described_class.new(io: file_io, clock: -> { "T" }, fsync: true)

      journal.record("type" => "x")

      expect(file_io).to have_received(:fsync).once
    end

    it "does not fsync when fsync mode is off (the default)" do
      file_io = instance_double(File, write: nil, "sync=": nil, fsync: nil)
      journal = described_class.new(io: file_io, clock: -> { "T" })

      journal.record("type" => "x")

      expect(file_io).not_to have_received(:fsync)
    end

    # NOT a StringIO: stringio 3.2.0 answers #fsync as a no-op returning 0, so it
    # would pass even without the respond_to? guard. A strict double that lacks
    # #fsync entirely raises on any unstubbed message -- deleting the guard makes
    # this example fail loudly, which is the point.
    it "attempts no fsync on an injected IO that lacks it, even with fsync: true" do
      bare_io = double("io without #fsync", write: nil, "sync=": nil)
      journal = described_class.new(io: bare_io, clock: -> { "T" }, fsync: true)

      expect { journal.record("type" => "x") }.not_to raise_error
    end
  end

  # The ONE duck every Journal reader speaks (Handler::Recorded, Ledger::Index):
  # a record is a Hash or one NDJSON line, and anything else answers nil so the
  # reader can skip lines that belong to other writers on a shared fd.
  describe ".parse" do
    it "passes a Hash through with its TOP-LEVEL keys string-keyed" do
      expect(described_class.parse({ type: "turn_usage", digest: "d" }))
        .to eq("type" => "turn_usage", "digest" => "d")
    end

    it "leaves nested hashes' keys alone -- record readers own their payloads" do
      parsed = described_class.parse({ type: "turn_usage", usage: { input_tokens: 1 } })
      expect(parsed).to eq("type" => "turn_usage", "usage" => { input_tokens: 1 })
    end

    it "parses an NDJSON line String" do
      expect(described_class.parse(%({"type":"tool_result","tool_use_id":"tu_1"})))
        .to eq("type" => "tool_result", "tool_use_id" => "tu_1")
    end

    it "answers nil for a line that is not JSON" do
      expect(described_class.parse("not json at all {")).to be_nil
    end

    it "answers nil for a JSON line that is not an object -- a record is a Hash" do
      expect(described_class.parse("42")).to be_nil
      expect(described_class.parse(%(["an","array"]))).to be_nil
    end
  end

  # The one walk every reader shares: entries coerced through .parse, foreign
  # lines skipped, optionally narrowed to a single record type.
  describe ".records" do
    let(:entries) do
      [
        { type: "turn_usage", digest: "d1" },
        %({"type":"tool_result","tool_use_id":"tu_1"}),
        "not json at all {",
        %({"type":"turn_usage","digest":"d2"})
      ]
    end

    it "coerces Hashes and NDJSON lines through .parse, skipping foreign lines" do
      expect(described_class.records(entries).map { |record| record["type"] }.to_a)
        .to eq(%w[turn_usage tool_result turn_usage])
    end

    it "narrows to one record type when given, String or Symbol" do
      expect(described_class.records(entries, type: "turn_usage").map { |record| record["digest"] }.to_a)
        .to eq(%w[d1 d2])
      expect(described_class.records(entries, type: :tool_result).map { |record| record["tool_use_id"] }.to_a)
        .to eq(%w[tu_1])
    end

    it "is lazy, so a stream can be read without materializing it" do
      endless = Enumerator.new { |y| loop { y << %({"type":"turn_usage","digest":"d"}) } }
      expect(described_class.records(endless, type: "turn_usage").first(2).size).to eq(2)
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
