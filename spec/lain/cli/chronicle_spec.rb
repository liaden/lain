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

    # T16: /fork composes `<session>@<head>` from this reader, so the opened
    # chronicle must name the very file `.for` put on disk.
    it "exposes the opened journal's path -- the session identity /fork forks" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        opened = described_class.for(enabled: true, paths:)

        expect(Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))).to eq([opened.journal_path])
        opened.close
      end
    end
  end

  it "answers no journal_path for an injected-io chronicle -- there is no file to fork" do
    expect(chronicle.journal_path).to be_nil
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

    # The WAL fd otherwise outlives the process's own close bracket: #close
    # closed the scribe and the journal, but the memoized spool -- a
    # long-lived append handle spanning every frame of the session -- had no
    # production caller of its own #close at all.
    it "#close closes the spool it opened, once the spool has actually been used" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        opened = described_class.for(enabled: true, paths:)

        spool = opened.spool
        expect(spool).to receive(:close).and_call_original
        opened.close
      end
    end

    # Never force the lazy open just to close it: a run that never spooled a
    # frame must still create no `.wal` file, even at teardown.
    it "#close does not open the spool merely to close it" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        opened = described_class.for(enabled: true, paths:)

        expect(Lain::Provider::ResponseWal).not_to receive(:new)
        opened.close

        expect(Dir.glob(File.join(dir, "lain", "sessions", "**", "*.wal"))).to be_empty
      end
    end
  end

  # T3 fix round: the ephemeral (--btw) lifecycle end-to-end through the
  # Chronicle. `.for(btw: true)` journals to the marked filename; a clean
  # `:exit` close reaps an UNPROMOTED ephemeral (journal + wal); every other
  # close reason leaves both for salvage, as does a hard kill (no code runs).
  # Promotion is exposed ON the chronicle because the chronicle owns the live
  # paths: it renames via {Lain::Paths::Ephemeral} AND retargets its own wal
  # derivation, so a lazily-opened first frame after promotion cannot
  # re-create the stale marked `.btw.wal`.
  describe "an ephemeral (--btw) chronicle" do
    around do |example|
      Dir.mktmpdir { |dir| @state_home = dir and example.run }
    end

    let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }

    def globbed(pattern) = Dir.glob(File.join(@state_home, "lain", "sessions", "**", pattern))

    def spool_frame(spool, digest: "blake3:abc")
      frame = spool.open_frame(request_digest: digest)
      frame.append("raw response bytes")
      frame.close(complete: true)
    end

    it ".for(btw: true) journals to <ts>-<pid>.btw.ndjson" do
      opened = described_class.for(enabled: true, btw: true, paths:)
      opened.start(context:, toolset:)

      names = globbed("*.btw.ndjson").map { |path| File.basename(path) }
      expect(names.size).to eq(1)
      expect(names.first).to match(/\A\d{8}T\d{6}-\d+\.btw\.ndjson\z/)
      opened.close(reason: :interrupted)
    end

    it "reaps journal and wal on a clean :exit close while unpromoted" do
      opened = described_class.for(enabled: true, btw: true, paths:)
      opened.start(context:, toolset:)
      spool_frame(opened.spool)
      expect(globbed("*.btw.wal").size).to eq(1)

      opened.close(reason: :exit)

      expect(globbed("*").select { |entry| File.file?(entry) }).to be_empty
    end

    it "leaves both files on any non-:exit close -- the crash-adjacent paths keep their salvage pair" do
      opened = described_class.for(enabled: true, btw: true, paths:)
      opened.start(context:, toolset:)
      spool_frame(opened.spool)

      opened.close(reason: :interrupted)

      expect(globbed("*.btw.ndjson").size).to eq(1)
      expect(globbed("*.btw.wal").size).to eq(1)
    end

    it "#promote! renames the pair, and the :exit close then keeps it" do
      opened = described_class.for(enabled: true, btw: true, paths:)
      opened.start(context:, toolset:)
      spool_frame(opened.spool)

      promoted = opened.promote!
      opened.close(reason: :exit)

      expect(File.exist?(promoted)).to be(true)
      expect(globbed("*.btw.*")).to be_empty
      expect(globbed("*.wal").map { |path| File.basename(path) })
        .to eq([File.basename(Lain::Paths.wal_for(promoted))])
    end

    it "keeps recording through the same journal fd after #promote! -- turns land in the promoted file" do
      opened = described_class.for(enabled: true, btw: true, paths:)
      opened.start(context:, toolset:)

      promoted = opened.promote!
      opened.catch_up(timeline)
      opened.close(reason: :exit)

      types = File.foreach(promoted).map { |line| JSON.parse(line)["type"] }
      expect(types.first).to eq("session")
      expect(types).to include("turn", "session_closed")
    end

    # The reviewer's trap: the spool memoizes BEFORE promotion, and the wal
    # opens lazily on the first frame -- a naive path capture would re-create
    # the stale marked `.btw.wal` after the rename.
    it "a first wal frame spooled AFTER #promote! lands at the promoted path" do
      opened = described_class.for(enabled: true, btw: true, paths:)
      opened.start(context:, toolset:)
      spool = opened.spool
      expect(globbed("*.wal")).to be_empty

      opened.promote!
      spool_frame(spool)

      expect(globbed("*.btw.wal")).to be_empty
      expect(globbed("*.wal").size).to eq(1)
      opened.close(reason: :interrupted)
    end

    it "frames spooled BEFORE promotion survive it, and later frames append to the same renamed wal" do
      opened = described_class.for(enabled: true, btw: true, paths:)
      opened.start(context:, toolset:)
      spool = opened.spool
      spool_frame(spool, digest: "blake3:before")

      opened.promote!
      spool_frame(spool, digest: "blake3:after")
      opened.close(reason: :interrupted)

      wals = globbed("*.wal")
      expect(wals.size).to eq(1)
      digests = Lain::Provider::ResponseWal.new(wals.first).frames.map(&:request_digest)
      expect(digests).to eq(%w[blake3:before blake3:after])
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

  # T19: a resumed chat opens a NEW chained journal -- the header names the
  # prior file (T14's resumed_from shape), and the scribe treats the resumed
  # chain's turns as already written, so catch_up records only what is new
  # and anchors its extends-check on the resumed head.
  describe "a resumed #start" do
    it "writes resumed_from into the open header and catch_up skips the already-written turns" do
      resumed_from = { "file" => "a.ndjson", "head" => timeline.head_digest }
      chronicle.start(context:, toolset:, resumed_from:, written: timeline.to_a.map(&:digest))

      expect(of_type("session").first).to include("head" => nil, "resumed_from" => resumed_from)

      extended = timeline.commit(role: :assistant, content: text("hello again"))
      chronicle.catch_up(extended)

      expect(of_type("turn").map { |record| record.fetch("digest") }).to eq([extended.head_digest])
    end

    it "keeps a fresh session's header byte-shape: no resumed_from key when not resuming" do
      chronicle.start(context:, toolset:)

      expect(of_type("session").first).not_to have_key("resumed_from")
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

    # I6: with --nvim's tee wrapped, Q/A message records ride it to the live
    # views (lain://inbox, StatusFeed) -- routed, never duplicated: the tee's
    # journal leg is this session's own journal, so the file still gets each
    # record exactly once.
    it "routes message records through the tee once #wrap_tee has run: file once, live sink too" do
      channel = []
      chronicle.wrap_tee(channel)
      chronicle.start(context:, toolset:)
      writer = Lain::Event::ChainWriter.new(observer: chronicle.observer)

      event = writer.put(timeline, kind: :message, from: "a", to: "human",
                                   causal_parents: [], body: { "question" => "q?" })

      expect(of_type("message").size).to eq(1)
      expect(of_type("message").first).to include("digest" => event.digest)
      expect(channel.map(&:class)).to eq([Lain::Telemetry::Message])
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

    it "prefers the tee once #wrap_tee has run, so --nvim fans telemetry to live views too" do
      chronicle.wrap_tee([])
      expect(chronicle.telemetry_kwargs.fetch(:journal)).to be_a(Lain::CLI::JournalTee)
    end
  end

  describe "#wrap_tee" do
    it "returns the SAME journal the scribe writes turns into -- not a second one" do
      expect(chronicle.wrap_tee([])).to be(journal)
    end

    it "fans telemetry onto both the underlying journal and the given channel" do
      channel = []
      chronicle.wrap_tee(channel)

      chronicle.telemetry_kwargs.fetch(:journal) << Lain::Telemetry::TurnUsage.new(
        digest: "blake3:t1", model: nil, stop_reason: :end_turn, usage: {}
      )

      expect(of_type("turn_usage").first).to include("digest" => "blake3:t1")
      expect(channel.size).to eq(1)
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

  # The proof of "one journal, and nothing downstream breaks": a REAL
  # Chronicle (through .for, exactly as the exe builds it), --nvim wired
  # through #wrap_tee, produces one session file carrying real turns, real
  # telemetry (request_sent/turn_usage/memory_root), AND an actual
  # nvim-shaped request_resent appended through the shared journal. The file
  # then round-trips through the SAME machinery a live resume/salvage would
  # use: Loader#recording must not raise, RequestReplay's baseline must
  # exclude the resend, and a salvage-style request_sent join must land on
  # the real dispatched request's digest, never the resend's.
  describe "end-to-end: a chronicle-produced file with an nvim resend round-trips clean" do
    it "loads through Loader, excludes the resend from RequestReplay, and salvage finds the real digest" do
      Dir.mktmpdir do |dir|
        real_paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
        chronicle = described_class.for(enabled: true, paths: real_paths)
        recorder = Lain::Memory::Recorder.new
        chronicle.wrap_memory(recorder)
        nvim_journal = chronicle.wrap_tee([])

        run_context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 16)
        chronicle.start(context: run_context, toolset: Lain::Toolset.new)

        store = Lain::Store.new
        write_input = { "id" => "aspirin", "description" => "dosing", "body" => "40mg/kg" }
        tool_use = { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write", "input" => write_input }
        tool_result = { "type" => "tool_result", "tool_use_id" => "tu_1", "is_error" => false,
                        "content" => [{ "type" => "text", "text" => "ok" }] }

        after_ask = Lain::Timeline.empty(store:).commit(role: :user, content: text("remember aspirin"))
        after_tool_use = after_ask.commit(role: :assistant, content: [tool_use])
        conversation = after_tool_use.commit(role: :user, content: [tool_result])
        chronicle.catch_up(conversation)

        # TurnUsage journals BEFORE the tool executes (Agent::Accounting's real
        # order), so the paired memory_root's root is the PRE-write snapshot --
        # matching what MemoryReplay itself reconstructs from the turn content.
        chronicle.telemetry_kwargs.fetch(:journal) << Lain::Telemetry::TurnUsage.new(
          digest: after_tool_use.head_digest, model: "claude-opus-4-8", stop_reason: :tool_use, usage: {}
        )
        recorder.write(Lain::Memory::Item.new(id: "aspirin", description: "dosing", body: "40mg/kg"))

        # A THIRD ask, dispatched but never answered -- the crash this file
        # is a stand-in for.
        request = Lain::Request.new(model: "claude-opus-4-8", max_tokens: 16,
                                    messages: [{ role: "user", content: "and ibuprofen?" }])
        chronicle.telemetry_kwargs.fetch(:journal) << Lain::Telemetry::RequestSent.new(
          digest: request.digest, payload: request.cache_payload, stream: request.stream,
          extra: request.extra, prefix_digests: request.prefix_digests
        )

        # The nvim-shaped hand-edit: a human resent the same in-flight request
        # from the editor, over the SAME journal the scribe writes into (the
        # split-second fix) -- never dispatched, must never read as a second
        # real request downstream.
        nvim_journal << Lain::Telemetry::RequestResent.new(
          digest: "blake3:hand-edited", payload: request.cache_payload, stream: request.stream,
          extra: request.extra
        )

        chronicle.close(reason: :exit)

        session_files = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))
        expect(session_files.size).to eq(1)
        session_path = session_files.first

        recording = Lain::Bench::Session::Loader.new(File.foreach(session_path)).recording

        expect(recording.timeline.to_a.map(&:digest)).to eq(conversation.to_a.map(&:digest))
        expect(recording.baseline.map(&:digest)).to eq([request.digest])
        # The paired memory_root agreed with MemoryReplay's own pre-write
        # snapshot (nil -- the index was still empty when TurnUsage journaled),
        # which is exactly what proves the record didn't raise Corrupt above.
        expect(recording.memory.roots.fetch(after_tool_use.head_digest)).to be_nil
        expect(recorder.root).not_to be_nil

        outcome = Lain::SessionRecord::Salvage.new(entries: File.foreach(session_path), frames: [],
                                                   timeline: recording.timeline)
                                              .call
        expect(outcome).to be_a(Lain::SessionRecord::Salvage::Incomplete)
        expect(outcome.request_digest).to eq(request.digest)
      end
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
      expect(null.journal_path).to be_nil
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

    # --no-journal + --nvim: no session record exists to share, so #wrap_tee
    # opens a REAL journal of its own -- the telemetry leg still exists
    # independent of the (absent) record.
    it "wrap_tee opens its OWN real journal and still carries the --nvim tee's telemetry leg" do
      fresh_journal = instance_double(Lain::Journal, :<< => nil)
      allow(Lain::Journal).to receive(:open).with(no_args).and_return(fresh_journal)

      returned = null.wrap_tee([])
      kwargs = null.telemetry_kwargs

      expect(returned).to be(fresh_journal)
      expect(kwargs.fetch(:journal)).to be_a(Lain::CLI::JournalTee)
      expect(kwargs.fetch(:model_middleware).to_a.first).to be_a(Lain::Middleware::JournalRequests)
    end

    # --no-journal's half of T17: no chronicle, no spool, no `.wal` file --
    # ever. Provider::Spool::Null never touches a filesystem by construction.
    it "answers Spool::Null so --no-journal creates no file" do
      expect(null.spool).to be_a(Lain::Provider::Spool::Null)
    end
  end
end
