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
    it "raises the Store's own MissingObject for an edge nothing in the file provides" do
      records = linked_messages(3)
      records.last["causal_parents"] = ["blake3:#{"ab" * 32}"]

      expect { replay(records).messages }.to raise_error(Lain::Store::MissingObject, /ababab/)
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
