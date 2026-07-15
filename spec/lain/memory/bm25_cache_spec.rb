# frozen_string_literal: true

# Memory::Bm25Cache memoizes a built Memory::Bm25 by Index#root -- equal
# roots are the same corpus by construction (content addressing), so a
# repeat root is served from the cache instead of paying Bm25's O(corpus)
# build again. See planning/specs/memory-read-path.md T3.
RSpec.describe Lain::Memory::Bm25Cache do
  def item(id, description, body: "body of #{id}")
    Lain::Memory::Item.new(id:, description:, body:)
  end

  def index_over(*items)
    store = Lain::Store.new
    items.inject(Lain::Memory::Index.empty(store:)) { |acc, entry| acc.write(entry) }
  end

  describe "#for" do
    it "returns the same Bm25 object (identity) for two snapshots sharing one root" do
      cache = described_class.new
      snapshot = index_over(item("aspirin-dosage", "Adult aspirin dosing guidance"))
      same_root = snapshot.checkout(snapshot.root)

      first = cache.for(snapshot)
      second = cache.for(same_root)

      expect(second).to equal(first)
    end

    it "builds fresh on a new root and searches the newly written item" do
      cache = described_class.new
      base = index_over(item("aspirin-dosage", "Adult aspirin dosing guidance", body: "aspirin 325mg"))
      cache.for(base)

      updated = base.write(item("ibuprofen-dosage", "Adult ibuprofen dosing", body: "ibuprofen 200mg"))
      bm25 = cache.for(updated)
      hit = bm25.search("ibuprofen").first

      expect(hit.id).to eq("ibuprofen-dosage")
      expect(hit.why).not_to be_empty
    end

    it "serves the empty index without an engine, and does not rebuild on repeat" do
      cache = described_class.new
      empty = Lain::Memory::Index.empty
      expect(Lain::Memory::Bm25).to receive(:new).once.and_call_original

      first = cache.for(empty)
      second = cache.for(empty)

      expect(first.search("anything")).to eq([])
      expect(second).to equal(first)
    end
  end
end
