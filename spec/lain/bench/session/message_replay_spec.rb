# frozen_string_literal: true

require "json"

# The flat-record replay: every event a render chain cannot carry, re-put into
# the Store a file rebuilds into. T2 gave it two record types that cite each
# other across the spawn boundary, so it can no longer put in strict file order
# -- and the SHAPE of what replaced that is a load-path property worth pinning,
# not an implementation detail. A journal is unbounded.
RSpec.describe Lain::Bench::Session::MessageReplay do
  # Counts what the solver asks of the Store. That is the whole complexity
  # question said mechanically: a greedy sweep asks once per record, while a
  # solver that evaluates the pending set before landing any of it asks
  # O(n^2) times and needs one pass -- historically one STACK FRAME -- per link.
  #
  # Anonymous rather than a named constant: it exists for two examples in this
  # file and has no business in the global namespace (`RSpec/LeakyConstantDeclaration`).
  counting_store = Class.new(SimpleDelegator) do
    attr_reader :lookups

    def initialize(store)
      super
      @lookups = 0
    end

    def key?(digest)
      @lookups += 1
      __getobj__.key?(digest)
    end
  end

  let(:counting) { counting_store.new(Lain::Store.new) }
  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  def as_record(journalable) = JSON.parse(JSON.generate(journalable.to_journal.transform_keys(&:to_s)))

  # A chain of `length` :message events, each naming the one before it -- the
  # exact shape a child chain's records also have, one link per turn.
  def linked_messages(length)
    base = Lain::Timeline.empty(store:).commit(role: :user, content: text("root"))
    written = []
    writer = Lain::Event::ChainWriter.new(
      observer: ->(event) { written << as_record(Lain::Telemetry::Message.from_event(event)) }
    )
    (1..length).inject(nil) do |last, index|
      writer.put(base, kind: :message, from: "a", to: "b",
                       causal_parents: [last&.digest].compact, body: { "n" => index })
    end
    written
  end

  def replay(records, into: Lain::Store.new, prior: [])
    described_class.new(records:, store: into, prior:)
  end

  describe "a file already in dependency order" do
    it "lands the whole file, in file order" do
      records = linked_messages(12)

      expect(replay(records).messages.map(&:digest)).to eq(records.map { |record| record["digest"] })
    end

    # THE guard. 400 linked records asked the Store 80,600 times before this was
    # a greedy sweep, one pass per link; the bound below is ~2 lookups a record.
    # {Event::Projection#causal_closure} records the same lesson from the other
    # direction -- a long chain is a log shape, not an error.
    it "asks the Store a linear number of times, not a quadratic one" do
      records = linked_messages(400)

      replay(records, into: counting).messages

      expect(counting.lookups).to be < records.size * 3
    end

    # Depth, not just count. A recursive solver carried one frame per link and
    # reached SystemStackError at roughly nine thousand records; this length is
    # chosen to be past that, so the example is about the stack rather than
    # about the clock.
    it "replays a chain deeper than a per-link stack frame survives" do
      records = linked_messages(12_000)

      expect(replay(records).messages.size).to eq(12_000)
    end
  end

  # The half of this class the Loader's fixpoint drives. `sweep` lands what it
  # can and REPORTS whether it moved -- that answer, and not an exception, is
  # what lets the Loader alternate this replay with the turn fold until neither
  # moves. It must also leave a record it could not land pending rather than
  # forcing it, or the fold would never get the chance to unblock it.
  describe "#sweep, the fixpoint's half-step" do
    # A message citing a TURN, which only the chain fold can land -- the exact
    # blocked shape the Loader alternates the two folds to unblock.
    def citing_a_turn
      root = Lain::Timeline.empty(store:).commit(role: :user, content: text("root"))
      cited = Lain::Event::ChainWriter.new.put(root, kind: :message, from: "a", to: "b",
                                                     causal_parents: [root.head_digest], body: { "n" => 1 })
      [root.head, as_record(Lain::Telemetry::Message.from_event(cited))]
    end

    it "answers true while it is landing records, and false once it has stalled" do
      replay = replay(linked_messages(3))

      expect(replay.sweep).to be(true)
      expect(replay.sweep).to be(false)
    end

    it "leaves a record whose cited turn is not landed YET pending, and takes it once it appears" do
      turn, record = citing_a_turn
      into = Lain::Store.new
      replay = replay([record], into:)

      expect(replay.sweep).to be(false)

      into.put(turn.carried_payload)
      into.put(turn)

      expect(replay.sweep).to be(true)
      expect(replay.messages.map(&:digest)).to eq([record["digest"]])
    end
  end

  describe "records whose edges cross" do
    # The cycle T2 could not order away: a question cites the turn it was asked
    # from, and the turn that delivers the answer cites the question back.
    it "lands a citing record written before the record it cites" do
      child = Lain::Timeline.empty(store:).commit(role: :user, content: text("child ask"))
      question = Lain::Event::ChainWriter.new.put(child, kind: :message, from: "child", to: "human",
                                                         causal_parents: [child.head_digest],
                                                         body: { "question" => "which db?" })
      records = [as_record(Lain::Telemetry::Message.from_event(question)),
                 as_record(Lain::Telemetry::ChildTurn.from_event(child.head))]

      expect(replay(records).messages.map(&:digest)).to eq([question.digest, child.head_digest])
    end
  end

  describe "what it still refuses" do
    # The Store still ENFORCES the edge; what changed is the currency the
    # refusal reaches a reader in. Which exception a damaged journal raises
    # cannot be an accident of whether the stuck record was a turn or a message
    # -- ChainFold has always translated the identical edge, and CLI::Resume,
    # Bench::CLI and Supervisor::Restart rescue different sets. The Store's own
    # sentence is carried through rather than reworded, so the digest a reader
    # needs is still in the message.
    it "raises Corrupt, carrying the Store's own sentence, for an edge nothing in the file provides" do
      records = linked_messages(3)
      records.last["causal_parents"] = ["blake3:#{"ab" * 32}"]

      expect { replay(records).messages }
        .to raise_error(Lain::Bench::Session::Corrupt) { |error|
          expect(error).not_to be_a(Lain::Store::MissingObject)
          expect(error.message).to include("message record 2", "ababab")
        }
    end

    # Panel fix round. Two record types share this index space, and the refusal
    # named the EVENT's kind -- so a damaged child_turn read "(turn)", a record
    # type the journal does not contain, in the one case this whole card exists
    # to re-open. The journal's own `type` is the honest label.
    it "names a damaged child_turn by its record type, not by the :turn kind it carries" do
      child = Lain::Timeline.empty(store:).commit(role: :user, content: text("brief"))
      stranded = Lain::Event.new(kind: :turn, carried_payload: child.head.carried_payload,
                                 from: nil, to: nil, render_parent: nil,
                                 causal_parents: ["blake3:#{"cd" * 32}"])

      expect { replay([as_record(Lain::Telemetry::ChildTurn.from_event(stranded))]).messages }
        .to raise_error(Lain::Bench::Session::Corrupt) { |error|
          expect(error.message).to include("record 0", "child_turn", "cdcdcd")
          expect(error.message).not_to include("(turn)")
        }
    end

    it "raises Corrupt for a record whose payload no longer re-derives its digest" do
      records = linked_messages(3)
      records.last["payload"] = { "n" => 99 }

      expect { replay(records).messages }.to raise_error(Lain::Bench::Session::Corrupt, /content address/)
    end
  end

  # The property that was traded away, pinned as a DECISION rather than left as
  # an accident. File position used to be an incidental integrity check: a
  # permuted section refused, because the Store saw the citing record first.
  # It cannot any more (see the class note), so what a permuted file gets is a
  # successful load whose returned log is that file's own order.
  describe "a permuted file, which used to refuse" do
    it "loads, and hands the log back in the file's order rather than the landing order" do
      records = linked_messages(5).reverse

      expect(replay(records).messages.map(&:digest)).to eq(records.map { |record| record["digest"] })
    end
  end
end
