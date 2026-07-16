# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# T13 integration round: the journal+scribe lifecycle, lifted out of the thin
# Thor executable the way CLI::Backend lifted provider resolution. The exe
# wires; the Chronicle owns WHEN the journal opens, what the scribe's header
# pins (the finished toolset -- hence the two-phase start), which journal
# telemetry lands in (tee || session journal), per-iteration turn durability,
# and how the record closes. Chronicle::Null is the --no-journal duck, so the
# exe carries no scribe nil-checks.
RSpec.describe Lain::CLI::Chronicle do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:store) { Lain::Store.new }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  subject(:chronicle) { described_class.new(journal:) }

  def text(body) = [{ "type" => "text", "text" => body }]

  let(:timeline) { Lain::Timeline.empty(store:).commit(role: :user, content: text("hi")) }

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
  def of_type(type) = records.select { |record| record["type"] == type }

  describe ".for" do
    it "opens a recording Chronicle on a Paths-based fsync journal when enabled" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        opened = described_class.for(enabled: true, paths:)

        expect(opened).to be_a(described_class)
        opened.start(context:, toolset:)
        session_files = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))
        expect(session_files.size).to eq(1)
        expect(JSON.parse(File.read(session_files.first).lines.first)).to include("type" => "session")
        opened.close
      end
    end

    it "answers the Null duck when journaling is off (--no-journal)" do
      expect(described_class.for(enabled: false)).to be_a(described_class::Null)
      expect(described_class.for(enabled: nil)).to be_a(described_class::Null)
    end
  end

  # T17's last obligation: chat must actually write a `.wal` when journaling
  # is on. #spool derives the sibling path from the SAME Journal.default_path
  # `.for` opened -- proven here by writing one frame and checking it landed
  # beside the NDJSON, not by trusting a stubbed path.
  describe "#spool" do
    it "opens no file until the spool is actually used" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        opened = described_class.for(enabled: true, paths:)

        expect(Dir.glob(File.join(dir, "lain", "sessions", "**", "*.wal"))).to be_empty
        opened.close
      end
    end

    it "spools a frame into <session-stem>.wal, beside the NDJSON" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        opened = described_class.for(enabled: true, paths:)

        frame = opened.spool.open_frame(request_digest: "blake3:abc")
        frame.append("hello")
        frame.close(complete: true)

        session_path = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson")).first
        wal_path = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.wal")).first
        expect(wal_path).to eq(session_path.sub(/\.ndjson\z/, ".wal"))
        opened.close
      end
    end

    it "memoizes the spool -- every provider this run builds tees into the SAME file" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        opened = described_class.for(enabled: true, paths:)

        expect(opened.spool).to be(opened.spool)
        opened.close
      end
    end
  end

  describe "two-phase start" do
    it "writes no header at construction; #start writes the OPEN header pinning the toolset" do
      chronicle
      expect(records).to be_empty

      chronicle.start(context:, toolset:)

      expect(of_type("session").first).to include("head" => nil, "model" => "claude-opus-4-8")
    end

    # Loud, not lossy: an event arriving before the scribe exists must raise,
    # never silently vanish -- pre-start is wiring time, when no event can flow.
    it "raises NotStarted from the observer (and catch_up) before #start" do
      event = Lain::Event::ChainWriter.new.put(timeline, kind: :message, from: "a", to: "b",
                                                         causal_parents: [], body: {})

      expect { chronicle.observer.call(event) }.to raise_error(described_class::NotStarted)
      expect { chronicle.catch_up(timeline) }.to raise_error(described_class::NotStarted)
    end
  end

  describe "#observer" do
    it "routes tool events to the scribe: a ChainWriter put lands as a message record" do
      chronicle.start(context:, toolset:)
      writer = Lain::Event::ChainWriter.new(observer: chronicle.observer)

      event = writer.put(timeline, kind: :message, from: "a", to: "human",
                                   causal_parents: [], body: { "question" => "q?" })

      expect(of_type("message").first).to include("digest" => event.digest)
    end
  end

  describe "#turn_middleware" do
    it "wires JournalTurns so each iteration's committed turns are journaled through the live-head thunk" do
      chronicle.start(context:, toolset:)
      live = timeline
      stack = chronicle.turn_middleware(-> { live })

      stack.call({ iteration: 0, timeline: }) do |env|
        live = live.commit(role: :assistant, content: text("yo"))
        env.merge(settled: true)
      end

      expect(of_type("turn").map { |record| record.fetch("digest") }).to eq(live.to_a.map(&:digest))
    end
  end

  describe "#telemetry_kwargs" do
    it "lands telemetry in the session journal, JournalRequests included" do
      kwargs = chronicle.telemetry_kwargs
      expect(kwargs.fetch(:journal)).to be(journal)
      expect(kwargs.fetch(:model_middleware).to_a.first).to be_a(Lain::Middleware::JournalRequests)
    end

    it "prefers the tee when --nvim fans telemetry to live views too" do
      tee = StringIO.new
      expect(described_class.new(journal:, tee:).telemetry_kwargs.fetch(:journal)).to be(tee)
    end
  end

  # T16 fix round: the write-side wiring for Session run-state. The chronicle
  # owns the decoration so the exe stays a one-line wire and Session itself
  # stays journal-ignorant (Session::Journaled's whole point).
  describe "#wrap_session" do
    it "returns a decorated session that journals a session_read on the first read only" do
      wrapped = chronicle.wrap_session(Lain::Session.new)

      wrapped.record_read("/tmp/app.rb")
      wrapped.record_read("/tmp/app.rb")

      reads = of_type("session_read")
      expect(reads.size).to eq(1)
      expect(reads.first).to include("path" => "/tmp/app.rb")
      expect(wrapped.read?("/tmp/app.rb")).to be(true)
    end

    it "journals todo snapshots into the session record" do
      wrapped = chronicle.wrap_session(Lain::Session.new)

      wrapped.write_todos([Struct.new(:content, :status).new("a", "pending")])

      expect(of_type("todo_snapshot").first)
        .to include("todos" => [{ "content" => "a", "status" => "pending" }])
    end
  end

  # Without this, real chat journals carry NO memory_root records and a
  # replay would silently rebuild empty memory: JournalMemoryRoot was wired
  # only on the bench paths (run_recorder, live_replay) until now.
  describe "#wrap_memory" do
    let(:recorder) { Lain::Memory::Recorder.new }

    it "returns the recorder itself, so Session and the memory tools keep their duck" do
      expect(chronicle.wrap_memory(recorder)).to be(recorder)
    end

    it "pairs each turn_usage through telemetry_kwargs' journal with the recorder's live root" do
      chronicle.wrap_memory(recorder)
      recorder.write(Lain::Memory::Item.new(id: "aspirin", description: "dosing", body: "40mg/kg"))

      chronicle.telemetry_kwargs.fetch(:journal) << Lain::Telemetry::TurnUsage.new(
        digest: "blake3:t1", model: nil, stop_reason: :end_turn, usage: {}
      )

      expect(of_type("memory_root").first).to include("turn_digest" => "blake3:t1", "root" => recorder.root)
    end

    it "leaves telemetry_kwargs' journal undecorated when no recorder was wrapped (run_recorder's raw-journal rule)" do
      expect(chronicle.telemetry_kwargs.fetch(:journal)).to be(journal)
    end
  end

  describe "lifecycle delegation" do
    before { chronicle.start(context:, toolset:) }

    it "catch_up journals the render chain; interrupted and close record the stop and the anchor" do
      chronicle.catch_up(timeline)
      chronicle.interrupted(head: timeline.head_digest)
      chronicle.close(reason: :exit)

      expect(of_type("turn").size).to eq(1)
      expect(of_type("run_interrupted").first).to include("head" => timeline.head_digest)
      expect(of_type("session_closed").first).to include("head" => timeline.head_digest, "reason" => "exit")
      expect(journal).to be_closed
    end
  end

  describe "#close before #start" do
    # chat's ensure runs even when wiring raised before the header was written:
    # close must not mask the original error, and a session_closed with no
    # header would be an orphan record.
    it "closes the journal, writes no session_closed, and does not raise" do
      expect { chronicle.close }.not_to raise_error
      expect(records).to be_empty
      expect(journal).to be_closed
    end
  end

  describe Lain::CLI::Chronicle::Null do
    subject(:null) { described_class.new }

    it "satisfies the whole duck and records nothing" do
      expect(null.observer).to be_a(Lain::Event::ChainWriter::Null)
      expect(null.start(context: nil, toolset: nil)).to be(null)
      expect(null.turn_middleware(-> {}).to_a).to be_empty
      expect(null.telemetry_kwargs).to eq({})
      expect(null.catch_up(nil)).to be(null)
      expect(null.interrupted(head: "x")).to be(null)
      expect(null.close(reason: :exit)).to be(null)
    end

    it "wraps session and memory as identity -- --no-journal decorates nothing" do
      session = Lain::Session.new
      recorder = Lain::Memory::Recorder.new

      expect(null.wrap_session(session)).to be(session)
      expect(null.wrap_memory(recorder)).to be(recorder)
    end

    it "still carries the --nvim tee's telemetry leg, which exists independent of the record" do
      tee = StringIO.new
      kwargs = described_class.new(tee:).telemetry_kwargs

      expect(kwargs.fetch(:journal)).to be(tee)
      expect(kwargs.fetch(:model_middleware).to_a.first).to be_a(Lain::Middleware::JournalRequests)
    end

    # --no-journal's half of T17: no chronicle, no spool, no `.wal` file --
    # ever. Provider::Spool::Null never touches a filesystem by construction.
    it "answers Spool::Null so --no-journal creates no file" do
      expect(null.spool).to be_a(Lain::Provider::Spool::Null)
    end
  end
end
