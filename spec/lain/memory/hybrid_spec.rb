# frozen_string_literal: true

# Memory::Hybrid is a Manifest::Hit-duck search index (T14) that fuses two
# ALREADY-BUILT arms -- a Memory::Bm25 (lexical) and a Memory::Vector
# (cosine) -- by Reciprocal Rank Fusion. It reads only each arm's RANK
# ordering, never the arm's own score: Bm25's token-fraction-ish scale and
# Vector's cosine scale are deliberately not comparable (the shared law
# group's own note), and RRF's whole design point is that rank position is
# the one thing every ranking already agrees how to compare.
RSpec.describe Lain::Memory::Hybrid do
  def item(id, description, body: "body of #{id}")
    Lain::Memory::Item.new(id:, description:, body:)
  end

  def index_over(*items)
    store = Lain::Store.new
    items.inject(Lain::Memory::Index.empty(store:)) { |acc, entry| acc.write(entry) }
  end

  # Same construction as vector_spec.rb: an explicit vocabulary derived from
  # the corpus itself, big enough to score every text and to let an
  # out-of-vocabulary query embed to the zero vector.
  def embedder_over(*texts)
    vocabulary = texts.join(" ").downcase.scan(/[a-z0-9]+/).uniq
    Lain::Embedder::Static.new(vocabulary:)
  end

  def hit(id, description, score: 1.0, why: "stub")
    Lain::Memory::Manifest::Hit.new(id:, description:, score:, why:)
  end

  describe "as a memory search index" do
    include_examples "a memory search index",
                     build: lambda { |corpus|
                       items = corpus.map { |id, description, body| item(id, description, body:) }
                       texts = corpus.flat_map { |_id, description, body| [description, body] }
                       described_class.new(
                         bm25: Lain::Memory::Bm25.new(index: index_over(*items)),
                         vector: Lain::Memory::Vector.new(index: index_over(*items), embedder: embedder_over(*texts))
                       )
                     },
                     search: ->(idx, query, k) { idx.search(query, k:) }
  end

  describe "#search" do
    # Scenario: fusion beats a disagreement (T14 acceptance). bm25's top hit
    # (decoy-a, rank 1) and vector's top hit (decoy-b, rank 1) differ; the
    # gold doc ranks second in BOTH. RRF must still put gold first: gold's
    # fused score (both terms near rank 2) beats either decoy's fused score
    # (one strong rank-1 term dragged down by a weak rank-4 term in the
    # other arm) once the arms disagree enough that consistency wins over a
    # single strong placement -- see hybrid.rb's CEILING doc for the exact
    # arithmetic this fixture is tuned against.
    it "ranks the doc both arms agree is second above either arm's own top pick, why citing both ranks" do
      bm25_order = %w[decoy-a gold filler decoy-b]
      vector_order = %w[decoy-b gold filler decoy-a]
      bm25 = instance_double(Lain::Memory::Bm25,
                             search: bm25_order.map { |id| hit(id, "#{id} description") })
      vector = instance_double(Lain::Memory::Vector,
                               search: vector_order.map { |id| hit(id, "#{id} description") })

      hits = described_class.new(bm25:, vector:).search("aspirin")

      expect(hits.first.id).to eq("gold")
      expect(hits.first.why).to include("bm25 rank 2").and include("vector rank 2")
    end

    it "names a source as unranked in #why when only the other arm surfaced the doc" do
      bm25 = instance_double(Lain::Memory::Bm25, search: [hit("only-bm25", "d")])
      vector = instance_double(Lain::Memory::Vector, search: [])

      hits = described_class.new(bm25:, vector:).search("aspirin")

      expect(hits.first.id).to eq("only-bm25")
      expect(hits.first.why).to include("bm25 rank 1").and include("vector unranked")
    end

    it "returns a Manifest::Hit-duck result" do
      bm25 = instance_double(Lain::Memory::Bm25, search: [hit("a", "aspirin dosing")])
      vector = instance_double(Lain::Memory::Vector, search: [])

      result = described_class.new(bm25:, vector:).search("aspirin").first

      expect(result).to be_a(Lain::Memory::Manifest::Hit)
      expect(result.id).to eq("a")
      expect(result.description).to eq("aspirin dosing")
      expect(result.score).to be_a(Float)
      expect(result.score).to be > 0
      expect(result.score).to be <= 1.0
    end

    it "is empty when both arms find nothing" do
      bm25 = instance_double(Lain::Memory::Bm25, search: [])
      vector = instance_double(Lain::Memory::Vector, search: [])

      expect(described_class.new(bm25:, vector:).search("zzznonexistent")).to eq([])
    end

    it "is deterministic across repeated calls" do
      bm25 = instance_double(Lain::Memory::Bm25, search: [hit("a", "a"), hit("b", "b")])
      vector = instance_double(Lain::Memory::Vector, search: [hit("b", "b"), hit("a", "a")])
      index = described_class.new(bm25:, vector:)

      expect(index.search("q")).to eq(index.search("q"))
    end

    it "bounds the result count by k" do
      bm25 = instance_double(Lain::Memory::Bm25, search: [hit("a", "a"), hit("b", "b"), hit("c", "c")])
      vector = instance_double(Lain::Memory::Vector, search: [])

      expect(described_class.new(bm25:, vector:).search("q", k: 2).size).to eq(2)
    end

    it "returns every match without k:" do
      bm25 = instance_double(Lain::Memory::Bm25, search: (1..5).map { |n| hit("n#{n}", "n#{n}") })
      vector = instance_double(Lain::Memory::Vector, search: [])

      expect(described_class.new(bm25:, vector:).search("q").size).to eq(5)
    end
  end
end
