# frozen_string_literal: true

RSpec.describe Lain::Timeline do
  subject(:timeline) { described_class.empty(store: store) }

  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, role: :user) = from.commit(role: role, content: text(body))

  describe "an empty timeline" do
    it "has no head" do
      expect(timeline).to be_empty
      expect(timeline.head).to be_nil
      expect(timeline.length).to eq(0)
    end

    it "rewinds to itself" do
      expect(timeline.rewind).to eq(timeline)
    end
  end

  describe "#commit" do
    it "advances the head" do
      one = say(timeline, "a")
      expect(one.head.content).to eq(text("a"))
      expect(one.length).to eq(1)
    end

    it "leaves the receiver untouched" do
      say(timeline, "a")
      expect(timeline).to be_empty
    end

    it "chains parents" do
      two = say(say(timeline, "a"), "b", role: :assistant)
      expect(two.head.parent).to eq(two.rewind.head_digest)
    end

    it "orders #to_a root first, which is the order a provider wants" do
      three = say(say(say(timeline, "a"), "b", role: :assistant), "c")
      expect(three.to_a.map { |t| t.content.first["text"] }).to eq(%w[a b c])
    end

    it "orders #ancestors head first" do
      three = say(say(say(timeline, "a"), "b", role: :assistant), "c")
      expect(three.ancestors.map { |t| t.content.first["text"] }).to eq(%w[c b a])
    end
  end

  describe "time travel" do
    let(:three) { say(say(say(timeline, "a"), "b", role: :assistant), "c") }

    it "rewinds one turn by default" do
      expect(three.rewind.head.content).to eq(text("b"))
    end

    it "rewinds n turns" do
      expect(three.rewind(2).head.content).to eq(text("a"))
    end

    it "rewinds past the root to the empty timeline rather than raising" do
      expect(three.rewind(99)).to be_empty
    end

    it "checks out any digest in the store" do
      expect(three.checkout(three.rewind(2).head_digest).head.content).to eq(text("a"))
    end

    it "refuses to check out a digest the store has never seen" do
      expect { three.checkout("sha256:nope") }.to raise_error(Lain::Store::MissingObject)
    end
  end

  describe "#fork" do
    it "is identity, because the value is immutable" do
      one = say(timeline, "a")
      expect(one.fork).to equal(one)
    end

    # The reason the Store is a separate object: a shared prefix is stored once,
    # so branching allocates nothing.
    it "stores a shared prefix exactly once" do
      base = say(say(timeline, "a"), "b", role: :assistant)
      left = say(base.fork, "left")
      right = say(base.fork, "right")

      expect(store.size).to eq(4) # a, b, left, right
      expect(left.rewind).to eq(right.rewind)
      expect(left).not_to eq(right)
    end
  end

  describe "the meet semilattice under ancestry" do
    let(:base) { say(say(timeline, "a"), "b", role: :assistant) }
    let(:left) { say(say(base, "l1"), "l2", role: :assistant) }
    let(:right) { say(base, "r1") }

    it "finds the greatest common ancestor" do
      expect(left.meet(right)).to eq(base)
    end

    it "exposes the divergence turn, which is what cache-break localization needs" do
      expect(left.diverge_at(right)).to eq(base.head)
    end

    it "aliases #& to #meet" do
      expect(left & right).to eq(base)
    end

    it "meets to the empty timeline when two roots share no history" do
      other_root = say(described_class.empty(store: store), "unrelated")
      expect(left.meet(other_root)).to be_empty
    end

    it "returns nil from #diverge_at when there is no shared history" do
      other_root = say(described_class.empty(store: store), "unrelated")
      expect(left.diverge_at(other_root)).to be_nil
    end

    it "refuses to compare across stores" do
      stranger = say(described_class.empty(store: Lain::Store.new), "x")
      expect { left.meet(stranger) }.to raise_error(described_class::CrossStore)
    end

    describe "the laws" do
      # Build a random forest over one store, then assert the meet laws on
      # randomly chosen members. Randomized because a hand-picked shape is
      # exactly where an associativity bug hides.
      let(:population) do
        timelines = [say(timeline, "root")]
        30.times { |i| timelines << say(timelines.sample, "n#{i}") }
        timelines
      end

      it "is idempotent" do
        population.sample(10).each { |a| expect(a.meet(a)).to eq(a) }
      end

      it "is commutative" do
        10.times do
          a, b = population.sample(2)
          expect(a.meet(b)).to eq(b.meet(a))
        end
      end

      it "is associative" do
        10.times do
          a, b, c = population.sample(3)
          expect(a.meet(b).meet(c)).to eq(a.meet(b.meet(c)))
        end
      end

      it "orders a meet below both operands" do
        10.times do
          a, b = population.sample(2)
          m = a.meet(b)
          expect(m.ancestor_of?(a)).to be(true)
          expect(m.ancestor_of?(b)).to be(true)
        end
      end
    end
  end

  describe "#ancestor_of?" do
    let(:base) { say(timeline, "a") }
    let(:child) { say(base, "b", role: :assistant) }

    it "is true for a prefix" do
      expect(base.ancestor_of?(child)).to be(true)
    end

    it "is false for a descendant" do
      expect(child.ancestor_of?(base)).to be(false)
    end

    it "is reflexive" do
      expect(base.ancestor_of?(base)).to be(true)
    end

    it "puts the empty timeline below everything" do
      expect(timeline.ancestor_of?(child)).to be(true)
    end
  end

  describe "equality (Regular)" do
    it "is by head digest" do
      one = say(timeline, "a")
      expect(one).to eq(one.fork)
      expect(one).not_to eq(say(timeline, "b"))
    end

    it "returns an Integer from #hash" do
      expect(say(timeline, "a").hash).to be_a(Integer)
    end

    it "deduplicates in a Set" do
      one = say(timeline, "a")
      expect(Set[one, one.fork].size).to eq(1)
    end
  end

  # Subagents get a fresh root over the shared store; the parent's head is
  # recorded in meta, not as a Turn parent, so it never renders into the prompt.
  describe "subagent lineage" do
    let(:parent) { say(timeline, "parent work") }

    let(:child) do
      described_class.empty(store: store)
                     .commit(role: :user, content: text("child task"),
                             meta: { "spawned_from" => parent.head_digest })
    end

    it "gives the child a root that does not chain to the parent" do
      expect(child.head).to be_root
      expect(child.length).to eq(1)
    end

    it "shares no prompt history with the parent" do
      expect(child.meet(parent)).to be_empty
    end

    it "keeps causal lineage recoverable from meta" do
      expect(child.head.meta["spawned_from"]).to eq(parent.head_digest)
    end

    it "shares the store, so the forest is one object database" do
      expect(store.key?(parent.head_digest)).to be(true)
      expect(store.key?(child.head_digest)).to be(true)
    end
  end
end
