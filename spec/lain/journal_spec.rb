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

    it "does not rebuild the keys of an entry that already has String keys" do
      entry = { "type" => "t", "n" => 1 }
      allow(entry).to receive(:transform_keys).and_call_original

      journal.record(entry)

      expect(entry).not_to have_received(:transform_keys)
      expect(JSON.parse(lines.first)).to eq("ts" => "T", "type" => "t", "n" => 1)
    end

    it "writes every journaled telemetry type as the line and chain digests its string-keyed hash gives" do
      includers = GenericBuild.value_classes.select { |klass| klass.include?(Lain::Telemetry::Journalable) }
      records = GenericBuild.partition(includers).first.map(&:last)
      legacy = records.map { |record| record.to_journal.transform_keys(&:to_s) }
      write = lambda do |entries|
        out = StringIO.new
        chained = described_class.new(io: out, clock: -> { "T" }, chain: described_class::Line::ORIGIN)
        entries.each { |entry| chained.record(entry) }
        out.string
      end

      expect(records.size).to be > 50
      expect(write.call(records)).to eq(write.call(legacy))
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
  # A caller whose records only make sense together -- a retreat and the turn
  # that replaces what it retreated past -- needs them in ONE write, so a
  # process killed between two records cannot leave the first alone.
  describe ".hash_of" do
    it "unwraps a #to_journal record and passes a Hash through" do
      record = Struct.new(:id) { def to_journal = { "type" => "t", "id" => id } }.new(7)

      expect(described_class.hash_of(record)).to eq("type" => "t", "id" => 7)
      expect(described_class.hash_of("a" => 1)).to eq("a" => 1)
    end

    it "refuses an entry that is neither" do
      expect { described_class.hash_of(:stray) }.to raise_error(TypeError, /got Symbol/)
    end
  end

  describe "#record_all" do
    it "writes every record, in order, in one write" do
      writes = []
      allow(io).to(receive(:write).and_wrap_original { |original, bytes| writes << bytes and original.call(bytes) })

      journal.record_all([{ "type" => "rewound", "to" => nil }, { "type" => "turn", "digest" => "abc" }])

      expect(writes.size).to eq(1)
      expect(lines.map { |line| JSON.parse(line)["type"] }).to eq(%w[rewound turn])
    end

    it "refuses once closed" do
      journal.close

      expect { journal.record_all([{ "a" => 1 }]) }.to raise_error(described_class::Closed)
    end
  end

  describe ".payload_of" do
    def chained_line(entry)
      chained = described_class.new(io:, clock: -> { "T" }, chain: described_class::Line::ORIGIN)
      chained.record(entry)
      described_class.parse(lines.last)
    end

    it "strips the stamp and the Journal's own link" do
      expect(described_class.payload_of(chained_line("type" => "t", "x" => 1))).to eq("type" => "t", "x" => 1)
    end

    it "gives an entry's own link back under its name" do
      expect(described_class.payload_of(chained_line("type" => "t", "prev" => "mine")))
        .to eq("type" => "t", "prev" => "mine")
    end
  end

  describe ".records with typed: true" do
    it "answers each record as the value it was written from" do
      record = Lain::Telemetry::Dropped.new(count: 2)
      journal.record(record)
      journal.record("type" => "turn", "digest" => "d")

      typed = described_class.records(io.string.lines, typed: true).to_a

      expect(typed.first).to eq(record)
      expect(typed.last).to have_attributes(type: "turn")
    end

    it "carries a torn record of our own whole rather than raising" do
      journal.record("type" => "ask_settled", "stop_reason" => "end_turn", "turns" => 1, "seconds" => 1.0)

      expect(described_class.records(io.string.lines, typed: true).to_a)
        .to contain_exactly(an_instance_of(Lain::Telemetry::Untyped).and(have_attributes(type: "ask_settled")))
    end
  end

  describe "#observe" do
    let(:observer_class) do
      Class.new do
        attr_reader :seen

        def initialize(&on_event)
          @seen = []
          @on_event = on_event
        end

        def <<(event)
          @seen << event
          @on_event&.call(event)
        end
      end
    end

    it "tells an observer every record, direct or teed, in write order, after each is on disk" do
      on_disk = []
      observer = observer_class.new { |event| on_disk << io.string.include?(%("type":"#{event["type"]}")) }
      journal.observe(observer)

      journal.record("type" => "direct")
      Lain::CLI::JournalTee.new(journal).record("type" => "teed")

      expect(observer.seen).to eq([{ "type" => "direct" }, { "type" => "teed" }])
      expect(on_disk).to eq([true, true])
    end

    it "tells an observer each entry of a batch, in order" do
      observer = observer_class.new
      journal.observe(observer)

      journal.record_all([{ "type" => "a" }, { "type" => "b" }])

      expect(observer.seen).to eq([{ "type" => "a" }, { "type" => "b" }])
    end

    it "keeps the record and journals the observer's error when the observer raises" do
      faulty = observer_class.new { |_event| raise ArgumentError, "fold failed" }
      journal.observe(faulty)

      journal.record("type" => "kept")

      records = lines.map { |line| JSON.parse(line) }
      expect(records.first).to include("type" => "kept")
      expect(records.last).to include(
        "type" => "journal_error", "observer" => faulty.class.to_s, "error" => "ArgumentError: fold failed",
        "entry_type" => "kept"
      )
      expect(records.last["backtrace"]).to include("journal_spec.rb")
    end

    it "names an object entry's class in the observer's journal_error" do
      journal.observe(observer_class.new { |_event| raise ArgumentError, "fold failed" })

      journal.record(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))

      expect(JSON.parse(lines.last)).to include("entry_type" => "Lain::Telemetry::ToolOutput")
    end

    it "does not re-enter an observer with the record it wrote back" do
      observer = observer_class.new do |event|
        journal.record("type" => "tripwire") unless event["type"] == "tripwire"
      end
      journal.observe(observer)

      journal.record("type" => "exec_record")

      expect(lines.map { |line| JSON.parse(line)["type"] }).to eq(%w[exec_record tripwire])
      expect(observer.seen).to eq([{ "type" => "exec_record" }])
    end

    it "still tells other observers a record one observer wrote back" do
      writer = observer_class.new { |_event| journal.record("type" => "tripwire") }
      watcher = observer_class.new
      journal.observe(writer)
      journal.observe(watcher)

      journal.record("type" => "exec_record")

      expect(watcher.seen.map { |event| event["type"] }).to eq(%w[tripwire exec_record])
    end

    it "tells an observer nothing another observer wrote during its callback" do
      first = observer_class.new { |event| journal.record("type" => "first_back") if event["type"] == "cause" }
      second = observer_class.new { |event| journal.record("type" => "second_back") if event["type"] == "first_back" }
      journal.observe(first)
      journal.observe(second)

      journal.record("type" => "cause")

      expect(first.seen.map { |event| event["type"] }).to eq(%w[cause])
      expect(lines.map { |line| JSON.parse(line)["type"] }).to eq(%w[cause first_back second_back])
    end

    it "does not tell an observer registered from a callback the record that triggered it" do
      late = observer_class.new
      registrar = observer_class.new { |event| journal.observe(late) if event["type"] == "trigger" }
      journal.observe(registrar)

      journal.record("type" => "trigger")
      journal.record("type" => "after")

      expect(late.seen).to eq([{ "type" => "after" }])
    end

    it "tells an observer records in file order under concurrent writers, direct and teed" do
      observer = observer_class.new { |_event| Thread.pass }
      journal.observe(observer)
      tee = Lain::CLI::JournalTee.new(journal)

      threads = Array.new(8) do |t|
        Thread.new { 100.times { |i| (t.even? ? journal : tee).record("type" => "w#{t}-#{i}") } }
      end
      threads.each(&:join)

      expect(observer.seen.map { |event| event["type"] }).to eq(lines.map { |line| JSON.parse(line)["type"] })
    end
  end

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

  # The fd is what keeps the record parseable, not a rule about who may call
  # `warn`. The Journal opens the session file itself and never stderr, so a
  # terminal write from anywhere in the process lands on fd 2 -- a descriptor no
  # reader of this file ever opens -- however badly it races with a record.
  describe "a stray terminal write while records are being written", :seam do
    # Warns from the deepest point a record reaches: while the line is still
    # being built, before the write takes the lock.
    let(:warns_while_encoding) do
      Class.new do
        def to_journal
          warn "a stray warning from lib/"
          { "type" => "noisy" }
        end
      end.new
    end

    # Reopens the process's REAL fd 2, so any unrelated warning emitted in this
    # window lands in `path` instead of the runner's output. Harmless: each
    # parallel_rspec worker is its own process and examples within one run
    # serially, so the window belongs to this example alone.
    def with_stderr_at(path)
      saved = $stderr.dup
      $stderr.reopen(path, "a")
      yield
    ensure
      $stderr.reopen(saved)
      saved.close
    end

    it "lands on fd 2, leaving every line of the record file parseable" do
      Dir.mktmpdir do |dir|
        record_path = File.join(dir, "session.ndjson")
        stderr_path = File.join(dir, "stderr.log")
        opened = described_class.open(record_path)

        with_stderr_at(stderr_path) do
          opened.record(warns_while_encoding)
          opened.record("type" => "after")
        end
        opened.close

        expect(File.readlines(record_path).map { |line| JSON.parse(line)["type"] }).to eq(%w[noisy after])
        expect(File.read(stderr_path)).to include("a stray warning from lib/")
      end
    end

    it "cannot tear a record even with four writers and a warning between each" do
      Dir.mktmpdir do |dir|
        record_path = File.join(dir, "session.ndjson")
        opened = described_class.open(record_path)

        with_stderr_at(File.join(dir, "stderr.log")) do
          Array.new(4) do |writer|
            Thread.new do
              50.times do |i|
                warn "noise from #{writer}"
                opened.record("type" => "row", "writer" => writer, "i" => i)
              end
            end
          end.each(&:join)
        end
        opened.close

        rows = File.readlines(record_path).map { |line| JSON.parse(line) }
        expect(rows.size).to eq(200)
        expect(rows.map { |row| [row["writer"], row["i"]] }.uniq.size).to eq(200)
      end
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

    # The block form is what a caller opening a journal for one bounded piece
    # of work wants -- {CLI::Consolidate} and {CLI::Improve} both do -- and it
    # exists because each of them had hand-written the same begin/ensure,
    # where the copy that drifts leaks an fd.
    describe "with a block" do
      it "answers what the block answered and closes the journal on the way out" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "s.ndjson")
          closed = nil

          answer = described_class.open(path) do |journal|
            journal.record("type" => "hello")
            closed = journal
            :the_block_value
          end

          expect(answer).to eq(:the_block_value)
          expect(closed).to be_closed
        end
      end

      it "closes it when the block RAISES, which is the whole reason for the bracket" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "s.ndjson")
          escaped = nil

          expect do
            described_class.open(path) do |journal|
              journal.record("type" => "hello")
              escaped = journal
              raise "the pass blew up"
            end
          end.to raise_error("the pass blew up")

          expect(escaped).to be_closed
        end
      end

      # {Unwritten#discard}'s rule reaches through the bracket unchanged: a
      # block that journaled nothing leaves no file behind.
      it "removes a file it created and never wrote to" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "s.ndjson")

          described_class.open(path) { |journal| journal }

          expect(File).not_to exist(path)
        end
      end
    end
  end

  # .open creates the file, but the session header lands much later
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

    # Another writer on the same file lands bytes we never see. Zero-byte
    # means the FILE is empty, not that this Journal happened not to write.
    it "keeps a file another writer landed bytes in" do
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
  # own unlink reproductions, ported: every one of them is a file the Journal
  # must NOT remove.
  describe "the unlink is pinned to the inode it created, never to the path" do
    around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

    def path_for(name) = File.join(@dir, name)

    # Reachable today: Resume::Salvager reopens a crashed session's file,
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

    # The comment this replaces reasoned only about a rename AWAY from the
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

    # File.size? follows a symlink while unlink removes the link itself --
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

    # THE one that decides it. Chronicle and ChatLaunch both document two
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

  # The ONE duck every Journal reader speaks (Oracle::Recorded, Ledger::Index):
  # a record is a Hash or one NDJSON line, and anything else answers nil so the
  # reader can skip lines that belong to other writers.
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

    it "returns every turn and no child_turn from a mixed session" do
      lines = [%({"type":"turn","n":1}), %({"type":"child_turn","n":2}), %({"type":"request_sent"}),
               "junk {", %({"type":"turn","n":3,"meta":{"type":"child_turn"}})]
      expect(described_class.records(lines, type: "turn").map { |record| record["n"] }.to_a).to eq([1, 3])
    end

    it "parses only the lines that name the type" do
      lines = Array.new(100) { %({"type":"request_sent","n":#{_1}}) } << %({"type":"turn","n":1})
      allow(JSON).to receive(:parse).and_call_original
      described_class.records(lines, type: "turn").to_a
      expect(JSON).to have_received(:parse).once
    end

    it "still ignores a nested type match" do
      line = %({"type":"other","body":{"type":"turn"}})
      expect(described_class.records([line], type: "turn").to_a).to eq([])
    end

    it "filters Hash entries by type" do
      entries = [{ type: "turn", n: 1 }, { type: "child_turn", n: 2 }]
      expect(described_class.records(entries, type: :turn).map { |record| record["n"] }.to_a).to eq([1])
    end

    it "is lazy, so a stream can be read without materializing it" do
      endless = Enumerator.new { |y| loop { y << %({"type":"turn_usage","digest":"d"}) } }
      expect(described_class.records(endless, type: "turn_usage").first(2).size).to eq(2)
    end
  end

  # Each line names the line before it, so an edit, insertion or removal anywhere in a session file
  # breaks the link of the line after it.
  describe "a chained journal" do
    around { |example| Dir.mktmpdir { |dir| @path = File.join(dir, "s.ndjson") and example.run } }

    def file_lines = File.read(@path).lines
    def parsed = file_lines.map { |line| JSON.parse(line) }
    def link(line) = Lain::Journal::Line.link(line)

    it "links every line of a new file to the one before it, the first to the origin" do
      described_class.open(@path, chain: true) do |opened|
        3.times { |n| opened.record("type" => "turn", "n" => n) }
      end

      expect(parsed.map { |record| record["prev"] })
        .to eq([Lain::Journal::Line::ORIGIN, link(file_lines[0]), link(file_lines[1])])
    end

    it "keeps ts and type leading the line and puts prev last" do
      described_class.open(@path, chain: true) { |opened| opened.record("type" => "turn", "n" => 1) }

      expect(parsed.first.keys).to eq(%w[ts type n prev])
    end

    it "chains the entries of one record_all in file order" do
      described_class.open(@path, chain: true) do |opened|
        opened.record_all([{ "type" => "rewound" }, { "type" => "turn" }])
      end

      expect(parsed.last["prev"]).to eq(link(file_lines.first))
    end

    it "continues a reopened file's chain from its last complete line" do
      described_class.open(@path, chain: true) { |opened| opened.record("type" => "session") }
      before = file_lines.last

      described_class.open(@path, chain: true) { |opened| opened.record("type" => "session_closed") }

      expect(parsed.last["prev"]).to eq(link(before))
    end

    it "links a record written back by an observer after the batch that caused it" do
      described_class.open(@path, chain: true) do |opened|
        echo = Class.new { define_method(:<<) { |entry| opened.record("type" => "echo") if entry["type"] == "turn" } }
        opened.observe(echo.new)
        opened.record_all([{ "type" => "turn" }, { "type" => "usage" }])
      end

      expect(parsed.map { |record| record["type"] }).to eq(%w[turn usage echo])
      expect(parsed.last["prev"]).to eq(link(file_lines[1]))
    end

    it "links a journal_error that stands in for an entry JSON cannot encode" do
      described_class.open(@path, chain: true) do |opened|
        opened.record("type" => "turn")
        opened.record("type" => "bad", "blob" => BasicObject.new)
        opened.record("type" => "turn")
      end

      expect(parsed.map { |record| record["type"] }).to eq(%w[turn journal_error turn])
      expect(parsed.drop(1).map { |record| record["prev"] }).to eq(file_lines.first(2).map { |line| link(line) })
    end

    it "renames an entry's own prev, so no entry can forge its link" do
      forger = Object.new
      def forger.to_journal = { "type" => "turn", "prev" => "x" }

      described_class.open(@path, chain: true) { |opened| opened.record(forger) }

      expect(parsed.first).to include("prev" => Lain::Journal::Line::ORIGIN, "entry_prev" => "x")
      expect(file_lines.first.scan('"prev":').size).to eq(1)
    end

    def batch(thread, seq)
      blob = "x" * ((seq % 5).zero? ? 50_000 : 10)
      seq.even? ? [{ "type" => "t#{thread}", "b" => blob }] : [{ "type" => "a" }, { "type" => "b", "b" => blob }]
    end

    def links_intact?
      file_lines.each_cons(2).all? { |before, line| JSON.parse(line)["prev"] == link(before) }
    end

    # A crash can leave a line without its newline. Sealing it makes it a line of its own that the
    # next record vouches for, rather than bytes glued onto the front of that record.
    it "seals a torn tail on reopen and links the next record to the torn bytes" do
      described_class.open(@path, chain: true) { |opened| opened.record("type" => "turn") }
      File.open(@path, "ab") { |file| file.write(%({"ts":"x","type":"tu)) }

      described_class.open(@path, chain: true) { |opened| opened.record("type" => "session_closed") }

      expect(file_lines.size).to eq(3)
      expect(JSON.parse(file_lines.last)).to include("type" => "session_closed", "prev" => link(file_lines[1]))
      expect(file_lines[1]).to eq(%({"ts":"x","type":"tu\n))
    end

    it "keeps the tip at the last line that landed when a write raises" do
      flaky = Class.new(StringIO) do
        attr_accessor :refuse

        def write(*)
          raise Errno::ENOSPC if refuse

          super
        end
      end.new
      chained = described_class.new(io: flaky, chain: Lain::Journal::Line::ORIGIN)
      chained.record("type" => "landed")
      flaky.refuse = true
      expect { chained.record("type" => "lost") }.to raise_error(Errno::ENOSPC)
      flaky.refuse = false

      chained.record("type" => "after")

      landed, after = flaky.string.lines
      expect(JSON.parse(after)["prev"]).to eq(link(landed))
    end

    it "keeps every link intact under threads writing records and batches at once" do
      described_class.open(@path, chain: true) do |opened|
        Array.new(6) do |thread|
          Thread.new do
            40.times do |n|
              entries = batch(thread, n)
              entries.one? ? opened.record(entries.first) : opened.record_all(entries)
            end
          end
        end.each(&:join)
      end

      expect(file_lines.size).to eq(6 * 60)
      expect(links_intact?).to be(true)
    end

    # Two appenders would each keep their own tip and fork the chain.
    it "refuses a second chained writer on the same file while the first is open" do
      first = described_class.open(@path, chain: true)

      expect { described_class.open(@path, chain: true) }.to raise_error(described_class::Locked, /#{@path}/)
      first.close
      expect { described_class.open(@path, chain: true).close }.not_to raise_error
    end

    def open_fds = Dir.children("/proc/self/fd").size

    it "closes its fd when a chained open is refused" do
      holder = described_class.open(@path, chain: true)
      before = open_fds

      expect { described_class.open(@path, chain: true) }.to raise_error(described_class::Locked)
      expect(open_fds).to eq(before)
    ensure
      holder&.close
    end

    it "closes its fd and lets the lock go when reading the tip raises" do
      File.write(@path, %({"type":"turn"}\n))
      allow(Lain::Journal::Line).to receive(:tip).and_raise(Errno::EIO)
      before = open_fds

      expect { described_class.open(@path, chain: true) }.to raise_error(Errno::EIO)
      expect(open_fds).to eq(before)
      allow(Lain::Journal::Line).to receive(:tip).and_call_original
      expect { described_class.open(@path, chain: true).close }.not_to raise_error
    end

    # A shared log opened without the chain must not slip lines into a chat's file, and a chat must
    # not start chaining a file shared writers still append to.
    it "refuses an unchained writer while a chained one holds the file" do
      holder = described_class.open(@path, chain: true)
      before = open_fds

      expect { described_class.open(@path) }.to raise_error(described_class::Locked, /#{@path}/)
      expect(open_fds).to eq(before)
    ensure
      holder&.close
    end

    it "refuses a chained writer while an unchained one holds the file" do
      holder = described_class.open(@path)

      expect { described_class.open(@path, chain: true) }.to raise_error(described_class::Locked, /#{@path}/)
    ensure
      holder&.close
    end

    it "lets unchained writers share a file, as the drain and worktree logs do" do
      first = described_class.open(@path)
      second = described_class.open(@path)
      first.record("type" => "a")
      second.record("type" => "b")
      [first, second].each(&:close)

      expect(parsed.map { |record| record["type"] }).to eq(%w[a b])
    end

    it "journals an entry carrying both prev and entry_prev as an error, keeping the chain" do
      described_class.open(@path, chain: true) do |opened|
        opened.record("type" => "turn")
        opened.record("type" => "turn", "prev" => "x", "entry_prev" => "y")
      end

      expect(JSON.parse(file_lines.last)).to include("type" => "journal_error", "error" => /entry_prev/)
      expect(links_intact?).to be(true)
    end

    it "refuses a tip that is neither the origin nor a blake3 link" do
      ["x", "blake3:abc", "blake3:#{"a" * 64}x", "blake3:#{"a" * 63}"].each do |tip|
        expect { described_class.new(io: StringIO.new, chain: tip) }
          .to raise_error(ArgumentError, /#{Regexp.escape(tip.inspect)}/)
      end
      expect { described_class.new(io: StringIO.new, chain: "blake3:#{"a" * 64}") }.not_to raise_error
    end

    it "does not chain a file opened without the keyword, as a shared log opens it" do
      described_class.open(@path) { |opened| 2.times { opened.record("type" => "drain") } }

      expect(parsed).to all(satisfy { |record| !record.key?("prev") })
    end

    it "does not chain a journal over an injected IO" do
      journal.record("type" => "turn")

      expect(JSON.parse(lines.first)).not_to have_key("prev")
    end

    it "leaves an unchained entry's own prev as it was" do
      journal.record("type" => "turn", "prev" => "x")

      expect(JSON.parse(lines.first)).to include("prev" => "x").and(satisfy { |record| !record.key?("entry_prev") })
    end
  end

  describe "its descriptor" do
    it "does not respond to fileno or share_fd" do
      expect(journal).not_to respond_to(:fileno, :share_fd)
    end
  end
end
