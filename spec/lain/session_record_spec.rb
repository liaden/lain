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
# A journal that lands `fail_after` records and then dies, the shape ENOSPC and
# EIO arrive in: the writes before it are on disk and stay there. `#recover`
# ends the outage so the same object can serve the retry, which is what makes
# the append point's position observable.
class FlakySessionJournal
  def initialize(fail_after:)
    @fail_after = fail_after
    @records = []
    @failing = true
  end

  def recover = @failing = false

  def <<(record)
    raise IOError, "no space left on device" if @failing && @records.size >= @fail_after

    @records << record
    self
  end

  def turn_digests
    @records.select { |record| record["type"] == "turn" }.map { |record| record["digest"] }
  end
end

RSpec.describe Lain::SessionRecord::Scribe do
  subject(:scribe) { described_class.new(journal:, context:, toolset:, workspace:) }

  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:store) { Lain::Store.new }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  # A user ask, an assistant tool_use, a user tool_result, an assistant reply --
  # the four render-chain turns one ask completes as. `text` is defined below:
  # a let body resolves it at example time, not here.
  let(:timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("hello"))
                  .commit(role: :assistant, content: [{ "type" => "tool_use", "id" => "tu_1",
                                                        "name" => "echo", "input" => { "text" => "hi" } }])
                  .commit(role: :user, content: [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                                   "content" => "hi" }])
                  .commit(role: :assistant, content: text("done"))
  end

  def text(body) = [{ "type" => "text", "text" => body }]
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

  # T14: the walk is BOUNDED, not merely correct. catch_up used to read the
  # whole ancestor chain and filter out what it had already written -- O(n) per
  # commit, so O(n^2) over a session, on the durability path every ask waits on.
  # The records are identical either way, so only the fetch count can tell a
  # bounded walk from a full one (spec/support/store_fetch_count.rb).
  describe "the catch_up walk is bounded by what is new" do
    it "visits only the new turn on a second catch_up, not the whole chain" do
      scribe.catch_up(timeline)
      grown = timeline.commit(role: :user, content: text("more"))
      fetches = count_store_fetches(store)

      scribe.catch_up(grown)

      # The new turn, then the last-written head the walk stops on.
      expect(fetches.count).to eq(2)
    end

    it "costs the same on a chain of forty as on a chain of four -- O(1) in the prefix" do
      expect(fetches_for_one_more_turn(40)).to eq(fetches_for_one_more_turn(4))
    end

    it "still visits the whole chain when there is no written head yet" do
      timeline # built BEFORE the count starts: every commit derives a correlation, which fetches
      fetches = count_store_fetches(store)

      scribe.catch_up(timeline)

      expect(fetches.count).to eq(4)
    end

    # A caught-up scribe on a chain `length` long, then the cost of catching it
    # up on exactly one more turn. Its own store and journal, so the two calls
    # this compares cannot see each other.
    def fetches_for_one_more_turn(length)
      chain = chain_of(length)
      caught_up = described_class.new(journal: Lain::Journal.new(io: StringIO.new), context:, toolset:, workspace:)
      caught_up.catch_up(chain)
      grown = chain.commit(role: :assistant, content: text("one more"))

      count_store_fetches(chain.store) { caught_up.catch_up(grown) }.count
    end

    def chain_of(length)
      (1..length).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |built, index|
        built.commit(role: :user, content: text("turn #{index}"))
      end
    end
  end

  # The bounded walk stops at the append point and never looks below it, which
  # is sound only while the written chain really IS the chain ending there --
  # in order, with no holes. Every move this class makes preserves that; the
  # `written:` seed is the one input that can arrive violating it, and a resume
  # is what supplies it (CLI::Resume::Result#written). So the seed is a CLAIM,
  # checked once against the first chain that can adjudicate it, rather than an
  # assumption four methods quietly share.
  describe "the written: seed is a claim, and it is checked" do
    let(:digests) { timeline.to_a.map(&:digest) }

    def seeded(written) = described_class.new(journal:, context:, toolset:, workspace:, written:)

    it "refuses a head that is not on the chain at all, journaling nothing" do
      scribe = seeded(["blake3:#{"a" * 64}"])
      before = journal_io.string.dup

      expect { scribe.catch_up(timeline) }
        .to raise_error(Lain::SessionRecord::Scribe::Diverged, /does not extend the written chain/)
      expect(journal_io.string).to eq(before)
    end

    # Panel probe P2d (Evans): the reversed seed's LAST entry is the root, which
    # is genuinely on-chain -- so the extends-check alone passes it, and every
    # turn the prior file already holds gets journaled a second time. That is
    # the doubling the `written:` doc warns about, arriving through the door
    # the doc did not guard.
    it "refuses a seed in the wrong order, even though its last entry is on-chain" do
      scribe = seeded(digests.reverse)
      before = journal_io.string.dup

      expect { scribe.catch_up(timeline) }.to raise_error(Lain::SessionRecord::Scribe::Diverged, /prefix/)
      expect(journal_io.string).to eq(before)
    end

    # Panel probe P2g: a holed seed reads as caught-up, and then #rewound prunes
    # it by INSERTION index and keeps a turn above the target -- a later rewind
    # to that turn would be a forward move wearing a rewind's name.
    it "refuses a seed with a hole in it, before a rewind can prune it wrongly" do
      scribe = seeded([digests[1], digests[0], digests[3]])

      expect { scribe.catch_up(timeline) }.to raise_error(Lain::SessionRecord::Scribe::Diverged, /prefix/)
    end

    # Re-review 3: order and holes are not the whole claim. A chain SUFFIX is in
    # order and unholed, and its head really is on the chain -- but the head is
    # then NOT the maximal written ancestor, because unwritten turns sit below
    # it. Costs one extra ancestor to catch: the head must be exactly `length`
    # deep, not merely `length` deep or more.
    it "refuses a seed that is a chain suffix, since the head must be the MAXIMAL written ancestor" do
      scribe = seeded(digests.last(2))
      before = journal_io.string.dup

      expect { scribe.catch_up(timeline) }.to raise_error(Lain::SessionRecord::Scribe::Diverged, /prefix/)
      expect(journal_io.string).to eq(before)
    end

    # Re-review 4: the seed is adjudicated by #catch_up, so every OTHER move has
    # to refuse while it is still a claim. #rewound is the sharp one -- it
    # journals a backward move whose `from:` comes from the unchecked seed, and
    # retreats the chain, both before any catch_up could have turned it down.
    # Today only call order stops that, and call order is a convention; the seed
    # being unvalidated was a convention too, which is how this card found it.
    it "refuses a rewind announced against a seed nothing has adjudicated yet" do
      scribe = seeded(digests.first(2))
      before = journal_io.string.dup

      expect { scribe.rewound(to: digests.first) }
        .to raise_error(Lain::SessionRecord::Scribe::Diverged, /never checked against a timeline/)
      expect(journal_io.string).to eq(before)
    end

    # The other half of that decision, pinned because it is the tempting fix
    # and it is wrong: `lain chat --resume` then quit-without-asking closes on
    # an unadjudicated seed, and it must NOT raise. Chronicle#close runs in
    # chat's `ensure`, so a refusal here turns a clean quit into a crash and
    # masks whatever was already unwinding. Nothing is risked -- no turn record
    # hangs off the anchor, because this record wrote none.
    it "closes on an unadjudicated seed rather than crashing a resumed session that asked nothing" do
      scribe = seeded(digests.first(2))

      scribe.close(reason: :exit)

      expect(of_type("session_closed").first).to include("head" => digests[1], "reason" => "exit")
    end

    it "marks run_interrupted on an unadjudicated seed for the same reason" do
      scribe = seeded(digests.first(2))

      scribe.interrupted

      expect(of_type("run_interrupted").first).to include("head" => digests[1])
    end

    # Panel probe P2e: the legitimate resume. A seed naming a mid-chain head is
    # a PREFIX, so it stands, and only the tail is journaled.
    it "accepts a seed that is a genuine prefix, journaling only the turns above it" do
      scribe = seeded(digests.first(2))

      scribe.catch_up(timeline)

      expect(of_type("turn").map { |record| record.fetch("digest") }).to eq(digests.last(2))
    end

    # The check walks the seed, so it has to be worth its cost: it runs against
    # the FIRST chain that can adjudicate it and never again. Per session, not
    # per ask -- which is exactly the budget the old filtered walk blew.
    it "checks the seed once, leaving later catch_ups at the bounded cost" do
      chain = chain_of(40)
      scribe = described_class.new(journal:, context:, toolset:, workspace:,
                                   written: chain.to_a.map(&:digest))
      scribe.catch_up(chain)
      grown = chain.commit(role: :user, content: text("more"))

      expect(count_store_fetches(chain.store) { scribe.catch_up(grown) }.count).to eq(2)
    end

    def chain_of(length)
      (1..length).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |built, index|
        built.commit(role: :user, content: text("turn #{index}"))
      end
    end
  end

  # Panel probe P5 (Evans): the append point must track the last record that
  # LANDED, not the last one the batch intended to write. A journal that dies
  # partway -- ENOSPC, EIO -- is a live path, not a thought experiment: a
  # {Middleware::JournalTurns} failure tears the ask into {CLI::Repl}'s
  # `record_interruption`, which catches the same scribe up again.
  describe "a journal that dies partway through a catch_up" do
    it "leaves the append point on the last landed turn, so the retry re-writes none of them" do
      flaky = FlakySessionJournal.new(fail_after: 3) # the header and two turns land; the third raises
      scribe = described_class.new(journal: flaky, context:, toolset:, workspace:)
      expect { scribe.catch_up(timeline) }.to raise_error(IOError)
      flaky.recover

      scribe.catch_up(timeline)

      expect(flaky.turn_digests).to eq(timeline.to_a.map(&:digest))
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

  # T15: {Scribe#rewound} is the ONE sanctioned backward move -- it announces
  # the rewind as an additive `rewound` record, so the {Diverged} raise above
  # keeps guarding every divergence that was NOT announced through it.
  describe "#rewound -- the announced backward move" do
    it "appends rewound {from:, to:} and moves the append point so post-rewind turns extend the target" do
      scribe.catch_up(timeline)
      target = timeline.rewind(2)

      scribe.rewound(to: target.head_digest)
      retried = target.commit(role: :user, content: text("try again"))
      scribe.catch_up(retried)

      expect(of_type("rewound"))
        .to contain_exactly(a_hash_including("type" => "rewound", "from" => timeline.head_digest,
                                             "to" => target.head_digest))
      expect(of_type("turn").last.fetch("digest")).to eq(retried.head_digest)
      expect(journal_io).to be_valid_ndjson
    end

    # The parent-hole this seam closes: a rewind-and-retry that re-commits
    # IDENTICAL content yields an identical digest, which the skip-set would
    # swallow -- the record would then jump from the rewound checkout straight
    # to a turn whose parent record never re-landed. Pruning the skip-set
    # above the target makes the re-made turn a fresh append in file order.
    it "prunes the skip-set above the target: an identical re-commit re-lands after the rewound record" do
      scribe.catch_up(timeline)

      scribe.rewound(to: timeline.rewind(1).head_digest)
      scribe.catch_up(timeline)

      expect(of_type("turn").size).to eq(5)
      expect(of_type("turn").last.fetch("digest")).to eq(timeline.head_digest)
      expect(records.map { |record| record.fetch("type") }).to eq(%w[session turn turn turn turn rewound turn])
    end

    it "anchors a graceful close at the post-rewind head" do
      scribe.catch_up(timeline)
      target = timeline.rewind(2)

      scribe.rewound(to: target.head_digest)
      scribe.close(reason: :exit)

      expect(of_type("session_closed").first).to include("head" => target.head_digest)
    end

    it "rewinds to the empty session with to: nil, the whole chain re-recordable" do
      scribe.catch_up(timeline)

      scribe.rewound(to: nil)
      scribe.catch_up(timeline)

      expect(of_type("rewound").first).to include("from" => timeline.head_digest, "to" => nil)
      expect(of_type("turn").size).to eq(8)
    end

    # T15 panel (Aaron): the prune, end to end through Scribe -> Loader,
    # twice over -- the same digest must re-land after EACH rewound record,
    # and the file must fold.
    it "double rewind with identical re-commits: the digest re-lands after each rewound and the file folds" do
      scribe.catch_up(timeline)
      scribe.rewound(to: timeline.rewind(1).head_digest)
      scribe.catch_up(timeline)
      scribe.rewound(to: timeline.rewind(1).head_digest)
      scribe.catch_up(timeline)

      expect(of_type("turn").count { |record| record["digest"] == timeline.head_digest }).to eq(3)
      loaded = Lain::Bench::Session::Loader.new(records).recording
      expect(loaded.timeline.head_digest).to eq(timeline.head_digest)
    end

    it "refuses a target never written to this record, the file unchanged" do
      scribe.catch_up(timeline)
      before = journal_io.string.dup

      expect { scribe.rewound(to: "blake3:#{"f" * 64}") }
        .to raise_error(Lain::SessionRecord::Scribe::Diverged, /never/)
      expect(journal_io.string).to eq(before)
    end

    it "keeps refusing an UNANNOUNCED divergence after a legitimate rewound -- the announce is per move" do
      scribe.catch_up(timeline)
      scribe.rewound(to: timeline.rewind(1).head_digest)
      diverged = timeline.rewind(3).commit(role: :user, content: text("other path"))

      expect { scribe.catch_up(diverged) }
        .to raise_error(Lain::SessionRecord::Scribe::Diverged, /does not extend the written chain/)
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

    # I6: the live inbox surfaces (nvim's lain://inbox, StatusFeed) fold Q/A
    # records off the telemetry tee, so the scribe routes its message records
    # through an injected sink when one is given -- ROUTED, not duplicated:
    # the tee's journal leg IS the session journal, so the record lands in the
    # file exactly once, and each live sink sees the same record.
    it "routes message records through an injected message_journal (a tee) with single delivery to the file" do
      sink = []
      tee = Lain::CLI::JournalTee.new(journal, sink)
      routed = described_class.new(journal:, context:, toolset:, workspace:, message_journal: tee)
      writer = Lain::Event::ChainWriter.new(observer: routed)

      question = writer.put(parent, kind: :message, from: parent.correlation, to: "human",
                                    causal_parents: [parent.head_digest], body: { "question" => "which file?" })

      expect(of_type("message").size).to eq(1) # the journal got it ONCE, via the tee's journal leg
      expect(of_type("message").first).to include("digest" => question.digest)
      expect(sink.size).to eq(1)
      expect(sink.first).to be_a(Lain::Telemetry::Message)
      expect(sink.first.digest).to eq(question.digest)
    end

    # Turn records are unaffected by the routing: they are record data, not
    # live-view telemetry, and stay on the journal directly.
    it "keeps turn records on the session journal even when a message_journal is injected" do
      sink = []
      routed = described_class.new(journal:, context:, toolset:, workspace:,
                                   message_journal: Lain::CLI::JournalTee.new(journal, sink))

      routed.catch_up(timeline)

      expect(of_type("turn").size).to eq(4)
      expect(sink).to be_empty
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

# C2: the turn record's causal edge. `causal_parents` is part of the content
# address (Event#payload), so a record that drops it cannot be re-committed back
# to its own digest -- and the empty set writes NO key, `resumed_from`'s idiom,
# so every turn without a causal edge stays byte-identical to what this writer
# emitted before the field existed.
RSpec.describe Lain::SessionRecord do
  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  def message(to:, body:)
    payload = Lain::Event::Payload.new(kind: :message, body: { "text" => body })
    store.put(payload)
    Lain::Event.new(kind: :message, carried_payload: payload, from: "human", to:).tap do |event|
      store.put(event)
    end
  end

  # AC2: a turn with no causal parents is unchanged -- proven as BYTES, against
  # a COMMITTED fixture recorded before this field existed. Its first turn line
  # is re-committed from its own recorded content and re-journaled under its own
  # recorded timestamp; anything but a byte-for-byte match means the format
  # moved under every session already on disk.
  describe ".turn, for a turn with no causal parents" do
    fixture = File.expand_path("../fixtures/sessions/variance/one.ndjson", __dir__)

    let(:line) { File.readlines(fixture).find { |raw| JSON.parse(raw)["type"] == "turn" } }
    let(:recorded) { JSON.parse(line) }

    let(:turn) do
      Lain::Timeline.empty(store:)
                    .commit(role: recorded.fetch("role"), content: recorded.fetch("content"),
                            meta: recorded.fetch("meta"))
                    .head
    end

    it "re-journals byte-identically to the committed pre-change record" do
      io = StringIO.new
      Lain::Journal.new(io:, clock: -> { recorded.fetch("ts") }) << described_class.turn(turn)

      expect(io.string).to eq(line)
    end

    it "writes no causal_parents key at all: absence, never an empty value" do
      expect(described_class.turn(turn)).not_to have_key("causal_parents")
    end
  end

  # AC1's writer half; the fold back is spec'd in bench/session/chain_fold_spec.
  describe ".turn, for a turn that folded two messages" do
    let(:asked) { message(to: "human", body: "which dose?") }
    let(:answered) { message(to: "agent", body: "81 mg") }

    let(:turn) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: text("what is the aspirin dosing?"))
                    .commit(role: :assistant, content: text("81 mg"),
                            causal_parents: [asked.digest, answered.digest])
                    .head
    end

    it "records both parent digests, in the sorted order the content address holds them" do
      expect(described_class.turn(turn).fetch("causal_parents")).to eq([asked.digest, answered.digest].sort)
    end
  end
end
