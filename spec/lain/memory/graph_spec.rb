# frozen_string_literal: true

# Memory::Graph is a Manifest::Hit-duck search index (T5): the seed layer is
# plain lexical matching (delegated to Memory::Manifest, the always-runs
# floor), then an optional N-hop walk across `[[wikilink]]` targets in item
# bodies pulls in items the seed pass never scored, each explaining itself
# via #why with the path that reached it.
RSpec.describe Lain::Memory::Graph do
  def item(id, description, body: "body of #{id}")
    Lain::Memory::Item.new(id:, description:, body:)
  end

  def index_over(*items)
    store = Lain::Store.new
    items.inject(Lain::Memory::Index.empty(store:)) { |acc, entry| acc.write(entry) }
  end

  describe "as a memory search index" do
    include_examples "a memory search index",
                     build: lambda { |corpus|
                       described_class.new(index: index_over(*corpus.map do |id, description, body|
                         item(id, description, body:)
                       end))
                     },
                     search: ->(idx, query, k) { idx.search(query, k:) }
  end

  describe "#search" do
    it "surfaces an item whose description mentions the query term, why naming the matched term" do
      graph = described_class.new(index: index_over(item("a", "Aspirin dosing guidance")))

      hits = graph.search("aspirin")

      expect(hits.map(&:id)).to eq(["a"])
      expect(hits.first.why).to include("aspirin")
    end

    it "does not cross a wikilink when hops is not given (default: no expansion)" do
      seed = item("a", "Aspirin dosing guidance", body: "See [[b]] for details")
      linked = item("b", "Unrelated topic, no shared terms", body: "nothing here")
      graph = described_class.new(index: index_over(seed, linked))

      expect(graph.search("aspirin").map(&:id)).to eq(["a"])
    end

    it "crosses one wikilink hop, and the hit's why names the path from the seed" do
      seed = item("a", "Aspirin dosing guidance", body: "See [[b]] for details")
      linked = item("b", "Unrelated topic, no shared terms", body: "nothing here")
      graph = described_class.new(index: index_over(seed, linked))

      hits = graph.search("aspirin", hops: 1)

      expect(hits.map(&:id)).to contain_exactly("a", "b")
      hop_hit = hits.find { |hit| hit.id == "b" }
      expect(hop_hit.why).to include("a").and include("b")
    end

    it "stops at the hop limit and never returns an item twice" do
      a = item("a", "Aspirin dosing guidance", body: "See [[b]]")
      b = item("b", "No shared terms here", body: "See [[c]]")
      c = item("c", "Also no shared terms", body: "a dead end")
      graph = described_class.new(index: index_over(a, b, c))

      hits = graph.search("aspirin", hops: 1)

      expect(hits.map(&:id)).to contain_exactly("a", "b")
      expect(hits.map(&:id).uniq).to eq(hits.map(&:id))
    end

    it "reaches a second-hop item when hops allows it" do
      a = item("a", "Aspirin dosing guidance", body: "See [[b]]")
      b = item("b", "No shared terms here", body: "See [[c]]")
      c = item("c", "Also no shared terms", body: "a dead end")
      graph = described_class.new(index: index_over(a, b, c))

      hits = graph.search("aspirin", hops: 2)

      expect(hits.map(&:id)).to contain_exactly("a", "b", "c")
    end

    it "ignores a wikilink that does not resolve to any item id" do
      seed = item("a", "Aspirin dosing guidance", body: "See [[nonexistent]] for details")
      graph = described_class.new(index: index_over(seed))

      expect { graph.search("aspirin", hops: 1) }.not_to raise_error
      expect(graph.search("aspirin", hops: 1).map(&:id)).to eq(["a"])
    end

    it "bounds the result count by k" do
      a = item("a", "Aspirin dosing guidance", body: "See [[b]] and [[c]]")
      b = item("b", "Also mentions aspirin dosing", body: "no links")
      c = item("c", "Also mentions aspirin dosing too", body: "no links")
      graph = described_class.new(index: index_over(a, b, c))

      expect(graph.search("aspirin", hops: 1, k: 1).size).to eq(1)
    end

    it "is empty when the query shares no tokens with any document and no seed to hop from" do
      graph = described_class.new(index: index_over(item("a", "Aspirin dosing guidance", body: "See [[b]]")))

      expect(graph.search("zzznonexistent qqquux", hops: 1)).to eq([])
    end

    it "returns Manifest::Hit-duck results" do
      graph = described_class.new(index: index_over(item("a", "Aspirin dosing guidance")))

      hit = graph.search("aspirin").first

      expect(hit).to be_a(Lain::Memory::Manifest::Hit)
    end

    it "constructs without raising over an empty index" do
      empty = described_class.new(index: index_over)

      expect(empty.search("aspirin")).to eq([])
    end
  end
end
