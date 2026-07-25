# frozen_string_literal: true

require "json"

# The file-order fold Loader delegates to: re-commit every turn record over the
# accumulated chain and verify each rebuild against the digest recorded beside
# it. C2's stake in it is the causal edge -- `causal_parents` is part of the
# content address, so a fold that drops it re-derives a DIFFERENT digest and
# raises Corrupt over bytes that are perfectly sound. The reader therefore has
# to feed it back to Timeline#commit; relaxing the verification instead would
# throw away the only integrity check the format has.
RSpec.describe Lain::Bench::Session::ChainFold do
  def text(body) = [{ "type" => "text", "text" => body }]

  # A real :message event, landed the way MessageReplay lands one (payload
  # first, then the envelope). Store#put enforces referential integrity over
  # causal_parents exactly as it does over the render edge, so a fold can only
  # rebuild a causal turn into a store that already holds what it names.
  def message_into(store, to:, body:)
    payload = Lain::Event::Payload.new(kind: :message, body: { "text" => body })
    store.put(payload)
    Lain::Event.new(kind: :message, carried_payload: payload, from: "human", to:).tap do |event|
      store.put(event)
    end
  end

  # AC1: a causal edge survives the round trip.
  describe "a turn committed with two causal parents" do
    let(:store) { Lain::Store.new }
    let(:asked) { message_into(store, to: "human", body: "which dose?") }
    let(:answered) { message_into(store, to: "agent", body: "81 mg") }

    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: text("what is the aspirin dosing?"))
                    .commit(role: :assistant, content: text("81 mg"),
                            causal_parents: [asked.digest, answered.digest])
    end

    let(:records) { timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) } }

    # A FRESH store holding only the two messages: the fold rebuilds the chain
    # from the records' bytes alone, so nothing it verifies is borrowed from
    # the store the turns were originally committed into.
    let(:fold) do
      fold_store = Lain::Store.new
      [asked, answered].each do |event|
        fold_store.put(event.carried_payload)
        fold_store.put(event)
      end
      described_class.new(records:, base: Lain::Timeline.empty(store: fold_store))
    end

    it "rebuilds the turn carrying both parent digests" do
      expect(fold.timeline.head.causal_parents).to eq([asked.digest, answered.digest].sort)
    end

    it "re-derives the journaled digest, so the fold verifies rather than raising Corrupt" do
      expect(fold.timeline.head_digest).to eq(timeline.head_digest)
      expect(fold.member?(timeline.head_digest)).to be(true)
    end
  end

  # AC3: an older journal still loads. Proven against a COMMITTED fixture --
  # every .ndjson in this repo was recorded before the field existed, so the
  # compatibility path is bytes on disk, never a hand-built record.
  describe "a recorded journal whose turn records predate causal_parents" do
    fixture = File.expand_path("../../../fixtures/sessions/variance/one.ndjson", __dir__)

    let(:records) { File.foreach(fixture).filter_map { |line| Lain::Journal.parse(line) } }

    it "carries no causal_parents key at all" do
      turns = records.select { |record| record["type"] == "turn" }
      expect(turns).not_to be_empty
      expect(turns.map(&:keys).flatten.uniq).not_to include("causal_parents")
    end

    it "folds without raising, and its turns carry no causal parents" do
      folded = described_class.new(records:, base: Lain::Timeline.empty(store: Lain::Store.new)).timeline

      expect(folded.to_a.map(&:role)).to eq(%w[user assistant user assistant])
      expect(folded.to_a.map(&:causal_parents)).to all(be_empty)
    end
  end

  # Review FIX 1. A turn's causal parent is a Store edge, so a fold that has
  # not landed the cited event gets Store::MissingObject -- an error NOTHING
  # rescues. Every other way this format can be wrong arrives as Corrupt, and
  # CLI::Resume rescues exactly Corrupt to build its Refusal, so letting this
  # one through turns a named refusal into a raw backtrace out of the exe.
  # Reachable live, not hypothetical: ToolRunner#delivery cites answered
  # ask_human questions, and ask_human is in the live toolset.
  describe "a turn citing a causal parent this fold never landed" do
    let(:store) { Lain::Store.new }
    let(:unlanded) { message_into(store, to: "agent", body: "81 mg") }

    let(:records) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: text("what is the aspirin dosing?"))
                    .commit(role: :assistant, content: text("81 mg"), causal_parents: [unlanded.digest])
                    .to_a.map { |turn| Lain::SessionRecord.turn(turn) }
    end

    # The fresh store IS the scenario: the message is in the journal, but this
    # fold has not replayed it into the store the chain rebuilds against.
    let(:fold) { described_class.new(records:, base: Lain::Timeline.empty(store: Lain::Store.new)) }

    it "raises Corrupt naming the record and the digest it cannot resolve" do
      expect { fold.timeline }.to raise_error(Lain::Bench::Session::Corrupt) do |error|
        expect(error.message).to include("turn record 1", "assistant", unlanded.digest)
      end
    end
  end

  # Review FIX 2. `meta` and `content` announce their corruption through the
  # digest they then fail to re-derive, and a bad `role` raises a named
  # InvalidRole -- but causal_parents cannot get that far, because
  # Event#normalize_causal maps and sorts it before any digest is computed. So
  # the one field this card added had the worst corrupt-journal message of any,
  # and it escaped the same rescue FIX 1 did. One currency: Corrupt.
  describe "a turn record whose causal_parents survived the disk badly" do
    def folded_with(causal_parents)
      base = Lain::Timeline.empty(store: Lain::Store.new)
      record = Lain::SessionRecord.turn(base.commit(role: :user, content: text("dose?")).head)
      described_class.new(records: [record.merge("causal_parents" => causal_parents)], base:).timeline
    end

    # Each of these raised something different and unrescued before the guard:
    # NoMethodError from three frames inside Event for the first three,
    # ArgumentError from #sort for the mixed array, MissingObject for the rest.
    {
      "a null" => nil,
      "a bare digest String" => "blake3:not-a-list",
      "a number" => 42,
      "an array mixing digests with a number" => ["blake3:a", 42],
      "an array of objects" => [{ "a" => 1 }]
    }.each do |shape, value|
      it "raises Corrupt naming the field for #{shape}" do
        expect { folded_with(value) }.to raise_error(Lain::Bench::Session::Corrupt, /causal_parents/)
      end
    end
  end
end
