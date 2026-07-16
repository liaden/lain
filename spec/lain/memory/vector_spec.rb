# frozen_string_literal: true

# Memory::Vector is a Manifest::Hit-duck search index (T10) over an injected
# Embedder (the batch #embed(texts) -> [[Float]] duck): items are embedded
# ONCE at construction -- Bm25's build-once shape, bm25.rb:32-42 -- and a
# query is scored against every item vector by exact cosine similarity, no
# ANN. Embedder::Static is the deterministic bench arm the laws and the
# scenario examples below are pinned against.
RSpec.describe Lain::Memory::Vector do
  def item(id, description, body: "body of #{id}")
    Lain::Memory::Item.new(id:, description:, body:)
  end

  def index_over(*items)
    store = Lain::Store.new
    items.inject(Lain::Memory::Index.empty(store:)) { |acc, entry| acc.write(entry) }
  end

  # A vocabulary big enough to score every text below built from the texts
  # themselves -- Static needs an explicit vocabulary, and deriving it from
  # the corpus is what lets an out-of-vocabulary query ("zzznonexistent")
  # embed to the zero vector the degenerate-corpus law needs.
  def embedder_over(*texts)
    vocabulary = texts.join(" ").downcase.scan(/[a-z0-9]+/).uniq
    Lain::Embedder::Static.new(vocabulary:)
  end

  describe "as a memory search index" do
    include_examples "a memory search index",
                     build: lambda { |corpus|
                       texts = corpus.flat_map { |_id, description, body| [description, body] }
                       described_class.new(
                         index: index_over(*corpus.map { |id, description, body| item(id, description, body:) }),
                         embedder: embedder_over(*texts)
                       )
                     },
                     search: ->(idx, query, k) { idx.search(query, k:) }
  end

  describe "#search" do
    # Scenario: nearest neighbor ranks first
    it "ranks the item nearest the query first, why naming the cosine score and embedder id" do
      x = item("x", "renal biopsy of the kidney")
      decoy = item("decoy", "unrelated liver enzyme panel")
      embedder = embedder_over("renal biopsy kidney unrelated liver enzyme panel")
      index = described_class.new(index: index_over(x, decoy), embedder:)

      hits = index.search("kidney biopsy")

      expect(hits.first.id).to eq("x")
      expect(hits.first.why).to include("cosine")
      expect(hits.first.why).to match(/\d\.\d+/)
      expect(hits.first.why).to include(embedder.class.name)
    end

    # Scenario: determinism and ties
    it "is deterministic and breaks equal scores by id, stable across repeated builds" do
      a = item("b-item", "aspirin dosing guidance")
      b = item("a-item", "aspirin dosing guidance")
      embedder = embedder_over("aspirin dosing guidance")

      first_build = described_class.new(index: index_over(a, b), embedder:)
      second_build = described_class.new(index: index_over(a, b), embedder:)

      hits = first_build.search("aspirin dosing")
      expect(hits.map(&:score).uniq.size).to eq(1) # both score identically
      expect(hits.map(&:id)).to eq(%w[a-item b-item]) # tie broken by id asc

      expect(second_build.search("aspirin dosing")).to eq(hits)
    end

    # Scenario: degenerate corpus
    it "returns [] without error over an empty index" do
      empty = described_class.new(index: index_over, embedder: embedder_over("anything"))

      expect { empty.search("aspirin") }.not_to raise_error
      expect(empty.search("aspirin")).to eq([])
    end

    it "is empty when the query embeds to the zero vector (no in-vocabulary terms)" do
      embedder = embedder_over("aspirin dosing")
      index = described_class.new(index: index_over(item("a", "aspirin dosing")), embedder:)

      expect(index.search("zzznonexistent qqquux")).to eq([])
    end

    it "returns a Manifest::Hit-duck result" do
      embedder = embedder_over("aspirin dosing")
      index = described_class.new(index: index_over(item("a", "aspirin dosing")), embedder:)

      hit = index.search("aspirin").first

      expect(hit).to be_a(Lain::Memory::Manifest::Hit)
      expect(hit.id).to eq("a")
      expect(hit.description).to eq("aspirin dosing")
    end

    it "bounds the result count by k" do
      items = (1..5).map { |n| item(format("note-%02d", n), "aspirin note #{n}") }
      embedder = embedder_over(*items.map(&:description))
      index = described_class.new(index: index_over(*items), embedder:)

      expect(index.search("aspirin", k: 2).size).to eq(2)
    end

    it "returns every positive match without k:" do
      items = (1..5).map { |n| item(format("note-%02d", n), "aspirin note #{n}") }
      embedder = embedder_over(*items.map(&:description))
      index = described_class.new(index: index_over(*items), embedder:)

      expect(index.search("aspirin").size).to eq(5)
    end
  end
end
