# frozen_string_literal: true

RSpec.describe Lain::Memory::Index do
  subject(:index) { described_class.empty(store:) }

  let(:store) { Lain::Store.new }

  def item(id, body = "v1")
    Lain::Memory::Item.new(id:, description: "about #{id}", body:)
  end

  describe "an empty index" do
    it "has no root" do
      expect(index).to be_empty
      expect(index.root).to be_nil
    end

    it "has no entries" do
      expect(index.to_h).to eq({})
    end

    it "is what checkout(nil) lands on" do
      one = index.write(item("a"))
      expect(one.checkout(nil)).to eq(index)
    end
  end

  describe "#write" do
    it "returns a new Index with a different root" do
      one = index.write(item("a"))
      two = one.write(item("b"))
      expect(one.root).not_to be_nil
      expect(two.root).not_to eq(one.root)
    end

    it "leaves the receiver untouched, which is what makes it persistent" do
      one = index.write(item("a"))
      one.write(item("b"))
      expect(index).to be_empty
      expect(one.to_h.keys).to eq(%w[a])
    end

    it "puts both the item and its node into the shared store" do
      one = index.write(item("a"))
      expect(store.key?(one.root)).to be(true)
      expect(store.key?(item("a").digest)).to be(true)
    end

    it "chains nodes by parent digest, Merkle-style" do
      one = index.write(item("a"))
      two = one.write(item("b"))
      expect(store.fetch(two.root).parent).to eq(one.root)
    end
  end

  describe "last write wins per id" do
    let(:after_v1) { index.write(item("dosage", "v1")) }
    let(:after_v2) { after_v1.write(item("dosage", "v2")) }

    it "resolves an id to its most recent item" do
      expect(after_v2.fetch("dosage").body).to eq("v2")
    end

    it "counts the id once" do
      expect(after_v2.to_h.keys).to eq(%w[dosage])
    end

    it "keeps the superseded write reachable via checkout" do
      expect(after_v2.checkout(after_v1.root).fetch("dosage").body).to eq("v1")
    end
  end

  describe "#fetch" do
    it "raises loudly on an unknown id" do
      expect { index.fetch("nope") }.to raise_error(described_class::UnknownId, /nope/)
    end

    it "raises a Lain::Error subclass, so one rescue catches the library" do
      expect(described_class::UnknownId.superclass).to eq(Lain::Error)
    end

    it "returns the item for a known id" do
      expect(index.write(item("a")).fetch("a")).to eq(item("a"))
    end
  end

  describe "#key?" do
    it "answers membership by id" do
      one = index.write(item("a"))
      expect(one.key?("a")).to be(true)
      expect(one.key?("b")).to be(false)
    end
  end

  # Nothing here shadows Enumerable: membership by id is #key? (the Store
  # precedent) and the id => Item map is #to_h, so Enumerable's own
  # #include? and #entries keep their contracts over the yielded Items.
  describe "the Enumerable contract" do
    it "answers #include? for a member Item" do
      one = index.write(item("a"))
      expect(one.include?(item("a"))).to be(true)
      expect(one.include?(item("b"))).to be(false)
    end

    it "means to_a by #entries" do
      idx = index.write(item("b")).write(item("a"))
      expect(idx.entries).to eq(idx.to_a)
    end
  end

  describe "#checkout" do
    it "refuses a root the store has never seen" do
      expect { index.checkout("blake3:nope") }.to raise_error(Lain::Store::MissingObject)
    end
  end

  describe "iteration" do
    it "yields items sorted by id, regardless of write order" do
      idx = index.write(item("b")).write(item("c")).write(item("a"))
      expect(idx.map(&:id)).to eq(%w[a b c])
    end

    it "returns an Enumerator when no block is given" do
      expect(index.each).to be_a(Enumerator)
    end

    it "is identical across walks, because sorted order is deterministic" do
      idx = index.write(item("gamma")).write(item("alpha")).write(item("beta"))
      expect(idx.to_a).to eq(idx.to_a)
    end
  end

  describe "immutability" do
    it "freezes the index" do
      expect(index).to be_frozen
      expect(index.write(item("a"))).to be_frozen
    end

    it "freezes the root digest" do
      expect(index.write(item("a")).root).to be_frozen
    end

    # The Index itself holds the shared mutable Store (as Timeline does), so
    # shareability is asserted on the stored values instead: every object the
    # walk touches must have no reachable mutable state.
    it "stores Nodes that are deeply immutable, hence Ractor-shareable" do
      one = index.write(item("a"))
      expect(Ractor.shareable?(store.fetch(one.root))).to be(true)
    end
  end

  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: -> { [index.write(item("a")), index.write(item("a"))] },
                     unequal: -> { index.write(item("b")) },
                     non_member: -> { index.write(item("a")).root }
  end

  describe "Node" do
    def node(id: "a", item: "blake3:abc", parent: nil)
      described_class::Node.new(id:, item:, parent:)
    end

    it "exposes the item's digest, not its content" do
      one = index.write(item("a"))
      expect(store.fetch(store.fetch(one.root).item_digest)).to eq(item("a"))
    end

    describe "equality (Regular)" do
      include_examples "a Regular value",
                       equal_pair: -> { [node, node] },
                       unequal: -> { node(id: "b") },
                       non_member: -> { node.digest }
    end
  end
end
