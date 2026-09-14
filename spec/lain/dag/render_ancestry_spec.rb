# frozen_string_literal: true

# The shared law group's default knobs are `a.meet(b)` and `m.ancestor_of?(a)`,
# and a Timeline does not answer `#meet`. Those defaults fit only a
# subject that carries its own meet, so the include below names the order's
# meet explicitly; leaving `meet:` off would fail every law with NoMethodError
# rather than say anything about the laws.
RSpec.describe Lain::Dag::RenderAncestry do
  let(:timeline) { Lain::Timeline.empty(store:) }

  let(:store) { Lain::Store.new }

  let(:base) { say(say(timeline, "a"), "b", role: :assistant) }
  let(:left) { say(say(base, "l1"), "l2", role: :assistant) }
  let(:right) { say(base, "r1") }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, role: :user) = from.commit(role:, content: text(body))

  # A fan-in (synthesis) event: it CONTINUES `from`'s render chain and names
  # the heads of `folds` as causal parents -- the cross-chain edges that make
  # the object graph a DAG.
  def fan_in(from, folds, body: "synthesis")
    from.commit(role: :assistant, content: text(body), causal_parents: folds.map(&:head_digest))
  end

  describe ".meet" do
    it "finds the greatest common ancestor" do
      expect(described_class.meet(left, right)).to eq(base)
    end

    it "is total at the bottom: a timeline meets the empty timeline at the empty timeline" do
      expect(described_class.meet(left, timeline)).to eq(timeline)
      expect(described_class.meet(timeline, left)).to eq(timeline)
    end

    it "meets to the empty timeline when two roots share no history" do
      other_root = say(Lain::Timeline.empty(store:), "unrelated")
      expect(described_class.meet(left, other_root)).to be_empty
    end

    it "refuses to compare across stores, by the name Timeline has always raised" do
      stranger = say(Lain::Timeline.empty(store: Lain::Store.new), "x")
      expect { described_class.meet(left, stranger) }
        .to raise_error(Lain::Timeline::CrossStore, "cannot compare Timelines backed by different stores")
      expect(Lain::Timeline::CrossStore).to equal(Lain::Dag::CrossStore)
    end

    # The meet builds `mine` (one side's ancestry, a Hash) eagerly -- that
    # side has to see everything to answer "is this digest in my history" at
    # all. The OTHER side is a #find over the other's ancestors, and #find can
    # stop the moment it lands on a digest already in `mine` -- it should never
    # keep walking toward the other's own root once the shared history is
    # reached.
    describe "cost: the find-side stops at the shared history" do
      it "walks past the answer only on the eager side, never on the find-side" do
        base_length = 60
        base = (1...base_length).inject(say(timeline, "0")) { |acc, i| say(acc, i.to_s) }
        mine = say(base, "mine")
        other = say(base, "other")

        tally = count_store_fetches(store) { described_class.meet(mine, other) }

        # mine's side walks its own whole chain (base_length + its own commit)
        # to build the membership hash; the find-side sees only other's own
        # head, then the shared base head where the two chains meet -- two
        # fetches, never another base_length worth.
        expect(tally.count).to eq(base_length + 1 + 2)
      end
    end
  end

  describe ".diverge_at" do
    it "names the last shared event, which is what cache-break localization needs" do
      expect(described_class.diverge_at(say(left.fork, "l3"), say(right.fork, "r2"))).to eq(base.head)
    end

    it "returns nil when there is no shared history" do
      other_root = say(Lain::Timeline.empty(store:), "unrelated")
      expect(described_class.diverge_at(left, other_root)).to be_nil
    end
  end

  describe ".below?" do
    it "is the render order's predicate: a prefix is below, a descendant is not, and it is reflexive" do
      expect(described_class.below?(base, left)).to be(true)
      expect(described_class.below?(left, base)).to be(false)
      expect(described_class.below?(base, base)).to be(true)
    end

    it "puts the empty timeline below everything" do
      expect(described_class.below?(timeline, left)).to be(true)
    end
  end

  # The meet and the divergence walk the render edge only; causal edges
  # landing in the Store must not perturb them. On single-parent render chains
  # they return exactly what they returned before causal edges existed.
  describe "the render meet under causal-edge insertion" do
    it "leaves the meet and the divergence exactly as before" do
      fan_in(left, [right])
      expect(described_class.meet(left, right)).to eq(base)
      expect(described_class.diverge_at(left, right)).to eq(base.head)
    end
  end

  describe "the laws" do
    # A random render forest, then fan-in events whose causal parents
    # cross-link the chains. To be precise about what this guards: the meet
    # walks the render edge only, and the fan-in members sit as leaves ON that
    # render tree, so no meet here ever traverses a causal edge -- this
    # population does not (cannot) exercise the meet "over a DAG". What it pins
    # is that ADDING causal cross-links to the Store leaves the render-tree meet
    # unperturbed. Randomized because a hand-picked shape is exactly where an
    # associativity bug hides.
    let(:population) do
      forest = MeetSemilatticePopulations.grow([say(timeline, "root")], 30, "n")
      10.times { |i| forest << MeetSemilatticePopulations.fan_in(forest.sample(3), "f#{i}") }
      forest
    end

    include_examples "a meet semilattice under ancestry",
                     population: -> { population },
                     meet: ->(a, b) { described_class.meet(a, b) },
                     ancestor_of: ->(m, a) { described_class.below?(m, a) }

    # The four shared laws hold for any semilattice whose order sits inside
    # ancestry -- `a == b ? a : empty` passes all of them -- so they cannot say
    # the meet is the GREATEST lower bound. This is the law that can.
    it "is the greatest lower bound: every common lower bound of both operands sits below the meet" do
      10.times do
        a, b = population.sample(2)
        meet = described_class.meet(a, b)
        common = population.select { |c| described_class.below?(c, a) && described_class.below?(c, b) }
        expect(common.reject { |c| described_class.below?(c, meet) }.map(&:head_digest)).to eq([])
      end
    end
  end
end
