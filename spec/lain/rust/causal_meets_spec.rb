# frozen_string_literal: true

# The causal ancestry order's maximal lower bounds on the Rust timeline -- git
# merge-base's shape. The answer is a SET of digests rather than a Timeline,
# because a criss-cross fan-in leaves incomparable common ancestors and any
# singleton among them would be arbitrary. That is also why nothing here
# includes a semilattice law group: the order implements `MaximalLowerBounds`
# rather than `MeetSemilattice`, and a law test would assert a structure it
# does not have.
#
# Rust is the only implementation, so no answer below is derived from a second
# one. Every fixture is small enough to check by hand, and every expectation
# names the events it must land on by the bodies they were committed with. The
# INDEPENDENT checks are the definition group at the end, which reads the order
# off its definition over a random union graph, and the named fixtures in
# `ext/lain/src/graph.rs`, which pin the algorithm beneath the binding.
RSpec.describe Lain::Ext::Timeline do
  let(:store) { Lain::Ext::Store.new }
  let(:empty) { described_class.empty(store:) }
  let(:graph) { criss_cross }
  let(:elsewhere) { described_class.empty(store: Lain::Ext::Store.new) }
  let(:refusal) { "cannot compare Timelines backed by different stores" }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, causal: [])
    from.commit(role: :user, content: text(body), causal_parents: causal)
  end

  # Three forks off one root, and two tips that each render off one fork while
  # causally folding the other two. `x`, `y` and `z` are pairwise incomparable
  # and every one of them is a common causal ancestor of both tips, so all three
  # are maximal and the answer's CARDINALITY IS THREE.
  #
  # That cardinality is the whole point of the fixture. An answer of one digest
  # cannot tell this operator apart from a plausible wrong one -- wrap the
  # dominator meet, or the render meet, in an array and a single-answer fixture
  # stays green while the operator is not this one. Here both of those answer
  # `root`, one element and the wrong one. Three is also the width that refutes
  # associativity under every single-valued reading.
  def criss_cross
    root = say(empty, "root")
    x = say(root, "x")
    y = say(root, "y")
    z = say(root, "z")
    { root:, x:, y:, z:,
      tip_x: say(x, "tip_x", causal: [y.head_digest, z.head_digest]),
      tip_y: say(y, "tip_y", causal: [x.head_digest, z.head_digest]) }
  end

  # `a -> b`, b forking to `left` and `right`, and two tips that each render off
  # one fork while causally folding the other -- the bottleneck the dominator
  # meet is pinned over. It answers TWO maximal lower bounds where that operator
  # answers the single `b`, so the two are separated here by an interior named
  # event rather than by a root.
  def bottleneck
    b = say(say(empty, "a"), "b")
    left = say(b, "left")
    right = say(b, "right")
    { b:, left:, right:,
      tip_left: say(left, "tip_left", causal: [right.head_digest]),
      tip_right: say(right, "tip_right", causal: [left.head_digest]) }
  end

  def digests(shape, *names) = names.map { |name| shape.fetch(name).head_digest }.sort

  describe "#causal_meets" do
    # The example that separates this operator from the two that would
    # plausibly be wired in its place: the answer is all three incomparable
    # bounds, where both of those answer the single `root`.
    it "answers every maximal lower bound, never an arbitrary one" do
      answer = graph[:tip_x].causal_meets(graph[:tip_y])
      expect(answer).to eq(digests(graph, :x, :y, :z))
      expect(answer).not_to include(graph[:root].head_digest)
      expect(graph[:tip_x].dominator_meet(graph[:tip_y])).to eq(graph[:root])
      expect(graph[:tip_x].meet(graph[:tip_y])).to eq(graph[:root])
    end

    it "answers both bounds where the dominator meet answers the one bottleneck" do
      shape = bottleneck
      answer = shape[:tip_left].causal_meets(shape[:tip_right])
      expect(answer).to eq(digests(shape, :left, :right))
      expect(shape[:tip_left].dominator_meet(shape[:tip_right])).to eq(shape[:b])
    end

    it "follows causal edges, seeing ancestry the render walk cannot" do
      expect(graph[:tip_x].causal_meets(graph[:y])).to eq(digests(graph, :y))
      expect(graph[:tip_x].meet(graph[:y])).to eq(graph[:root])
    end

    it "collapses to the ancestor's own head when one timeline is an ancestor of the other" do
      expect(graph[:x].causal_meets(graph[:tip_x])).to eq(digests(graph, :x))
    end

    it "is reflexive: a timeline's bounds with itself are its own head" do
      expect(graph[:tip_x].causal_meets(graph[:tip_x])).to eq(digests(graph, :tip_x))
    end

    # Digest order is the one canonical order incomparable elements admit, so it
    # is part of the contract rather than an implementation accident.
    it "answers digests in digest order" do
      answer = graph[:tip_x].causal_meets(graph[:tip_y])
      expect(answer.size).to be > 1
      expect(answer).to eq(answer.sort)
    end

    it "answers an Array of digest Strings, not a Timeline" do
      answer = graph[:tip_x].causal_meets(graph[:tip_y])
      expect(answer).to be_an(Array)
      expect(answer).to all(be_a(String))
    end

    # Asserted over the three-element answer on purpose: an empty Array is
    # deeply frozen for reasons that say nothing about the digests inside one.
    it "answers a deeply frozen array" do
      expect(graph[:tip_x].causal_meets(graph[:tip_y])).to be_deeply_frozen
    end

    it "answers nothing for heads sharing no causal history" do
      expect(graph[:tip_x].causal_meets(say(empty, "stranger"))).to eq([])
    end

    it "answers a deeply frozen array when it answers nothing" do
      expect(graph[:tip_x].causal_meets(say(empty, "stranger"))).to be_deeply_frozen
    end

    it "answers nothing for the empty timeline from either side" do
      expect(graph[:tip_x].causal_meets(empty)).to eq([])
      expect(empty.causal_meets(graph[:tip_x])).to eq([])
    end

    it "refuses a question across two stores, in the Rust class's own words" do
      expect { graph[:tip_x].causal_meets(elsewhere) }
        .to raise_error(described_class::CrossStore, refusal)
    end

    it "reads the store and never writes it" do
      tips = graph.values_at(:tip_x, :tip_y)
      expect { tips.first.causal_meets(tips.last) }.not_to change(store, :size)
    end
  end

  # The order taken from its definition rather than from any implementation:
  # a node's causal ancestry is itself plus everything its render and causal
  # parents reach, and the answer is the common ancestors that no other common
  # ancestor reaches. Exhaustive over the pairs of a random union graph.
  describe "against the definition (random union graphs)" do
    let(:population) { MeetSemilatticePopulations.union_graph(empty) }

    let(:reach) do
      Hash.new do |memo, digest|
        event = store.fetch(digest)
        parents = [event.render_parent, *event.causal_parents].compact
        memo[digest] = parents.reduce(Set[digest]) { |seen, parent| seen | memo[parent] }
      end
    end

    it "answers exactly the common ancestors no other common ancestor reaches, for every pair" do
      population.permutation(2).each do |a, b|
        common = reach[a.head_digest] & reach[b.head_digest]
        maximal = common.reject { |low| common.any? { |high| high != low && reach[high].include?(low) } }
        expect(a.causal_meets(b)).to eq(maximal.sort)
      end
    end
  end
end
