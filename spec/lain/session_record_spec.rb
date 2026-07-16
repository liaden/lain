# frozen_string_literal: true

require "json"
require "stringio"
require "tempfile"
require "tmpdir"

# T13: the live session scribe writes a LOADABLE session as a chat runs -- the
# same on-disk format Bench::Session records, so one Loader reads both, but
# written turn-by-turn (fsync'd) rather than in one final pass. The header is
# written OPEN (head: nil); a graceful close anchors the head, and a process
# that just stops leaves the open header behind. :message/:spawn events, which a
# Timeline walk can never see (their edges point backward, the Store has no
# forward enumerator), reach the scribe by observing the ChainWriter and land as
# a distinct `message` record that the turn loader skips.
RSpec.describe Lain::SessionRecord::Scribe do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:store) { Lain::Store.new }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  subject(:scribe) { described_class.new(journal:, context:, toolset:, workspace:) }

  def text(body) = [{ "type" => "text", "text" => body }]

  # A user ask, an assistant tool_use, a user tool_result, an assistant reply --
  # the four render-chain turns one ask completes as.
  let(:timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("hello"))
                  .commit(role: :assistant, content: [{ "type" => "tool_use", "id" => "tu_1",
                                                        "name" => "echo", "input" => { "text" => "hi" } }])
                  .commit(role: :user, content: [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                                   "content" => "hi" }])
                  .commit(role: :assistant, content: text("done"))
  end

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
  def of_type(type) = records.select { |record| record["type"] == type }

  # The Loader's own integrity check, inline: re-commit each turn record in file
  # order and demand it lands on the digest recorded beside it.
  def recommit_verifies?
    of_type("turn").inject(Lain::Timeline.empty(store: Lain::Store.new)) do |chain, record|
      rebuilt = chain.commit(role: record.fetch("role"), content: record.fetch("content"),
                             meta: record.fetch("meta"))
      raise "turn #{record.fetch("digest")} re-commits to #{rebuilt.head_digest}" unless
        rebuilt.head_digest == record.fetch("digest")

      rebuilt
    end
    true
  end

  it "writes the open header at construction, before any turn" do
    scribe
    expect(of_type("session").size).to eq(1)
    expect(of_type("session").first).to include("head" => nil, "context_class" => "Lain::Context",
                                                "model" => "claude-opus-4-8", "max_tokens" => 1024)
    expect(of_type("turn")).to be_empty
  end

  describe "a chat turn is on disk before the reply renders" do
    it "holds the header, the user turn, the assistant turn, and the tool_result turns, each re-commit-verifiable" do
      scribe.catch_up(timeline)

      expect(of_type("session").size).to eq(1)
      turns = of_type("turn")
      expect(turns.map { |record| record.fetch("role") }).to eq(%w[user assistant user assistant])
      expect(turns.map { |record| record.fetch("digest") }).to eq(timeline.to_a.map(&:digest))
      expect(recommit_verifies?).to be(true)
      expect(journal_io).to be_valid_ndjson
    end

    # Durability, not just correctness: with a real fsync'd file, the turns are
    # readable from an independent handle BEFORE the session closes -- which is
    # what "on disk before the reply renders" buys.
    it "fsyncs each turn to a real file, readable mid-session before any close" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "session.ndjson")
        durable = Lain::Journal.open(path, fsync: true)
        scribe = described_class.new(journal: durable, context:, toolset:, workspace:)

        scribe.catch_up(timeline)

        on_disk = File.read(path).each_line.map { |line| JSON.parse(line) }
        expect(on_disk.count { |record| record["type"] == "turn" }).to eq(4)
        expect(on_disk.last.fetch("digest")).to eq(timeline.head_digest)
      ensure
        durable&.close
      end
    end

    it "appends only the new turns on a second catch_up, in order, never re-writing the old" do
      scribe.catch_up(timeline)
      grown = timeline.commit(role: :user, content: text("more"))
                      .commit(role: :assistant, content: text("sure"))

      scribe.catch_up(grown)

      expect(of_type("turn").map { |record| record.fetch("digest") }).to eq(grown.to_a.map(&:digest))
    end
  end

  describe "an open session is recognizable (simulated SIGKILL: the process just stops)" do
    it "has a header with no anchor, no session_closed, and every turn still re-commits" do
      scribe.catch_up(timeline)

      expect(of_type("session").first.fetch("head")).to be_nil
      expect(of_type("session_closed")).to be_empty
      expect(of_type("run_interrupted")).to be_empty
      expect(recommit_verifies?).to be(true)
    end
  end

  describe "graceful close anchors the head" do
    it "writes a session_closed carrying the final head digest and the reason" do
      scribe.catch_up(timeline)
      scribe.close(reason: :exit)

      closed = of_type("session_closed")
      expect(closed.size).to eq(1)
      expect(closed.first).to include("head" => timeline.head_digest, "reason" => "exit")
    end

    it "defaults the anchor to the last caught-up head, so a closer need not repeat it" do
      scribe.catch_up(timeline)
      scribe.close(reason: :grace_expired)

      expect(of_type("session_closed").first).to include("head" => timeline.head_digest,
                                                         "reason" => "grace_expired")
    end

    it "rejects a reason outside the enum, loudly, before anything lands" do
      expect { scribe.close(reason: :kaput) }.to raise_error(ArgumentError, /reason must be one of/)
    end
  end

  # Panel probe D (Torvalds/Evans): dedupe-by-digest alone would append a
  # diverged tip AFTER the old chain -- on-disk records that only fail at LOAD
  # time, as Corrupt, far from the bug. The refusal must be write-time loud.
  describe "a rewound or diverged timeline is refused at write time" do
    it "raises the named refusal, the file unchanged past the last good record" do
      scribe.catch_up(timeline)
      before = journal_io.string.dup
      diverged = timeline.rewind(2).commit(role: :user, content: text("other path"))

      expect { scribe.catch_up(diverged) }
        .to raise_error(Lain::SessionRecord::Scribe::Diverged, /does not extend the written chain/)
      expect(journal_io.string).to eq(before)
    end

    it "refuses a plain rewind too -- moving the append point backward is the same corruption" do
      scribe.catch_up(timeline)

      expect { scribe.catch_up(timeline.rewind(1)) }
        .to raise_error(Lain::SessionRecord::Scribe::Diverged)
    end

    it "still accepts the same head twice (idempotent) and a straight extension" do
      scribe.catch_up(timeline)
      scribe.catch_up(timeline)
      grown = timeline.commit(role: :user, content: text("more"))

      expect { scribe.catch_up(grown) }.not_to raise_error
      expect(of_type("turn").last.fetch("digest")).to eq(grown.head_digest)
    end
  end

  describe "a run that a stop beat" do
    it "marks run_interrupted anchored at the last committed turn" do
      scribe.catch_up(timeline)
      scribe.interrupted

      expect(of_type("run_interrupted").first).to include("head" => timeline.head_digest)
    end
  end

  describe "ask_human Q&A survives (observed ChainWriter, not a Timeline walk)" do
    let(:parent) { Lain::Timeline.empty(store:).commit(role: :user, content: text("ask me")) }

    it "journals both :message events as `message` records, every envelope+body field pinned" do
      writer = Lain::Event::ChainWriter.new(observer: scribe)

      question = writer.put(parent, kind: :message, from: parent.correlation, to: "human",
                                    causal_parents: [parent.head_digest], body: { "question" => "which file?" })
      answer = writer.put(parent, kind: :message, from: "human", to: parent.correlation,
                                  causal_parents: [question.digest], body: { "answer" => "the readme" })

      messages = of_type("message")
      expect(messages.size).to eq(2)
      expect(messages.first).to include(
        "digest" => question.digest, "kind" => "message", "from" => parent.correlation,
        "to" => "human", "payload" => { "question" => "which file?" },
        "causal_parents" => question.causal_parents, "correlation" => question.correlation
      )
      expect(messages.last).to include(
        "digest" => answer.digest, "from" => "human", "to" => parent.correlation,
        "payload" => { "answer" => "the readme" }, "causal_parents" => [question.digest]
      )
    end

    it "records a :spawn event under the same additive `message` type, kind distinguishing it" do
      writer = Lain::Event::ChainWriter.new(observer: scribe)
      spawn = writer.put(parent, kind: :spawn, from: parent.correlation, to: nil,
                                 causal_parents: [parent.head_digest], body: { "spawned_from" => parent.head_digest })

      expect(of_type("message").first).to include("digest" => spawn.digest, "kind" => "spawn", "to" => nil)
    end

    # The escalation this seam exists to close: a scribe that raises must not be
    # swallowed. The ChainWriter's pinned contract is that the raise propagates
    # AFTER the Store write lands, so the record loss is loud, never silent.
    it "propagates a scribe failure out of the ChainWriter, the write already landed" do
      broken = described_class.new(journal:, context:, toolset:, workspace:)
      def broken.call(_event) = raise("scribe down")
      writer = Lain::Event::ChainWriter.new(observer: broken)

      expect { writer.put(parent, kind: :message, from: "a", to: "b", causal_parents: [], body: {}) }
        .to raise_error("scribe down")
      expect(store.key?(parent.head_digest)).to be(true)
    end
  end
end

# T16: the read side of Session::Journaled's write side. A journal that never
# saw a session_read/todo_snapshot/memory_root record (an older recording, or
# a run with no reads/writes) replays to the corresponding neutral state --
# the same tolerant zero-record precedent Bench::Session::MemoryReplay itself
# already sets for a memory_root-free chain.
RSpec.describe Lain::SessionRecord::Replay do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def todo(content, status) = Struct.new(:content, :status).new(content, status)

  def replayed_session(source = journal_io.string.each_line)
    described_class.new(source).session
  end

  # AC1: reads and todos round-trip.
  describe "reads and todos round-trip" do
    it "answers read? true for every recorded path and renders the LAST todo list only" do
      journaled = Lain::Session::Journaled.new(session: Lain::Session.new, journal:)
      journaled.record_read("/tmp/a.rb")
      journaled.record_read("/tmp/b.rb")
      journaled.write_todos([todo("first pass", "in_progress")])
      journaled.write_todos([todo("second pass", "completed")])

      fresh = replayed_session

      expect(fresh.read?("/tmp/a.rb")).to be(true)
      expect(fresh.read?("/tmp/b.rb")).to be(true)
      expect(fresh.read?("/tmp/never.rb")).to be(false)
      expect(fresh.reminders).to eq(["Current todo list:\n- [completed] second pass"])
    end

    it "accepts already-parsed Hash entries, not only raw NDJSON lines (the Journal.parse duck)" do
      journaled = Lain::Session::Journaled.new(session: Lain::Session.new, journal:)
      journaled.record_read("/tmp/a.rb")

      hashes = journal_io.string.each_line.map { |line| JSON.parse(line) }

      expect(replayed_session(hashes).read?("/tmp/a.rb")).to be(true)
    end

    it "skips foreign records the parse duck answers nil for" do
      journaled = Lain::Session::Journaled.new(session: Lain::Session.new, journal:)
      journaled.record_read("/tmp/a.rb")
      lines = ["not json at all\n", "[1, 2, 3]\n"] + journal_io.string.each_line.to_a

      expect(replayed_session(lines).read?("/tmp/a.rb")).to be(true)
    end

    it "replays cleanly to empty run-state from a journal with no session_read/todo_snapshot records" do
      Lain::SessionRecord::Scribe.new(journal:, context:, toolset:, workspace:)

      fresh = replayed_session

      expect(fresh.read?("/tmp/anything.rb")).to be(false)
      expect(fresh.reminders).to eq([])
    end
  end

  # AC2: the manifest pair needs no new record -- reconstructed through the
  # existing Bench::Session::MemoryReplay root, over the SAME turn/memory_root
  # records a memory-bearing run already journals.
  describe "the manifest pair needs no new record" do
    it "reconstructs manifest reminders through the existing MemoryReplay root" do
      recorder = Lain::Memory::Recorder.new
      memory_toolset = Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder:)])
      memory_journal = Lain::Memory::JournalMemoryRoot.new(journal:, recorder:)
      input = { "id" => "aspirin-dosing", "description" => "Aspirin dosing bounds", "body" => "40mg/kg max" }
      usage = Lain::Usage.new(input_tokens: 10, output_tokens: 5)
      responses = [tool_response(["tu_1", "memory_write", input], usage:, model: "claude-opus-4-8"),
                   text_response("done", usage:, model: "claude-opus-4-8")]

      agent, = record_journaled_run(responses, journal: memory_journal, toolset: memory_toolset, context:,
                                               workspace:)
      Lain::SessionRecord::Scribe.new(journal:, context:, toolset: memory_toolset, workspace:)
                                 .catch_up(agent.timeline)

      expect(replayed_session.reminders.last).to include("aspirin-dosing | Aspirin dosing bounds")
    end
  end
end
