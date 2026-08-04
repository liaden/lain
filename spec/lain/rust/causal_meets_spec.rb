# frozen_string_literal: true

# The causal ancestry order's maximal lower bounds on the Rust timeline -- git
# merge-base's shape. The answer is a SET of digests rather than a Timeline,
# because a criss-cross fan-in leaves incomparable common ancestors and any
# singleton among them would be arbitrary. That is also why nothing here
# includes a semilattice law group: Ruby declares this operator
# `not_a_meet_semilattice` and a law test would assert a structure both layers
# deny.
#
# Ruby is the oracle, over BOTH fixtures: every shape below is grown on the two
# implementations and their answers compared. "The same graph" is not an
# assumption -- both are driven through the identical sequence of public calls,
# and content addressing makes the resulting digests equal. Each parity example
# asserts that digest equality alongside the answers it compares, rather than
# leaning on another example to have run first; RSpec randomises order, so
# `grows the same graph on both implementations` is a standalone pin on the
# premise, not a precondition of anything.
RSpec.describe Lain::Ext::Timeline do
  let(:store) { Lain::Ext::Store.new }
  let(:ext_empty) { described_class.empty(store:) }
  let(:ruby_empty) { Lain::Timeline.empty }
  let(:ext_graph) { criss_cross(ext_empty) }
  let(:ruby_graph) { criss_cross(ruby_empty) }
  let(:ext_fan_in) { fan_in(ext_empty) }
  let(:ruby_fan_in) { fan_in(ruby_empty) }
  let(:elsewhere) { described_class.empty(store: Lain::Ext::Store.new) }

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
  # `root`, one element and the wrong one. Three is also the width Ruby's own
  # witness uses (`spec/support/algebra_generators.rb`'s `criss_cross`), because
  # it is what refutes associativity under every single-valued reading.
  #
  # Takes an empty timeline rather than building one, so the same calls grow the
  # same graph on either implementation.
  def criss_cross(empty)
    root = say(empty, "root")
    x = say(root, "x")
    y = say(root, "y")
    z = say(root, "z")
    { root:, x:, y:, z:,
      tip_x: say(x, "tip_x", causal: [y.head_digest, z.head_digest]),
      tip_y: say(y, "tip_y", causal: [x.head_digest, z.head_digest]) }
  end

  # `a -> b`, b forking to `left` and `right`, and two tips that each render off
  # one fork while causally folding the other -- the shape the dominator meet is
  # pinned over. It answers TWO maximal lower bounds where that operator answers
  # the single bottleneck `b`, so the two are separated here by an interior
  # named event rather than by a root, and neither operator's answer is a subset
  # of the other's.
  def fan_in(empty)
    b = say(say(empty, "a"), "b")
    left = say(b, "left")
    right = say(b, "right")
    { b:, left:, right:,
      tip_left: say(left, "tip_left", causal: [right.head_digest]),
      tip_right: say(right, "tip_right", causal: [left.head_digest]) }
  end

  # The refusal message from a real raise, so the two implementations' wording
  # can be compared byte for byte.
  def cross_store_message(timeline, other)
    timeline.causal_meets(other)
    raise "expected a cross-store causal_meets to be refused"
  rescue Lain::Error => e
    e.message
  end

  def digests(graph, *names) = names.map { |name| graph[name].head_digest }.sort

  describe "#causal_meets" do
    it "grows the same graph on both implementations" do
      expect(ext_graph.transform_values(&:head_digest))
        .to eq(ruby_graph.transform_values(&:head_digest))
    end

    it "answers the digests the Ruby timeline answers" do
      expect(ext_graph[:tip_x].causal_meets(ext_graph[:tip_y]))
        .to eq(ruby_graph[:tip_x].causal_meets(ruby_graph[:tip_y]))
    end

    # What stops the parity above from agreeing on nothing, and the example that
    # separates this operator from the two that would plausibly be wired in its
    # place: the answer is all three incomparable bounds, where both of those
    # answer the single `root`.
    it "answers every maximal lower bound, never an arbitrary one" do
      answer = ext_graph[:tip_x].causal_meets(ext_graph[:tip_y])
      expect(answer).to eq(digests(ext_graph, :x, :y, :z))
      expect(answer).not_to include(ext_graph[:root].head_digest)
      expect(ext_graph[:tip_x].dominator_meet(ext_graph[:tip_y]).head_digest)
        .to eq(ext_graph[:root].head_digest)
      expect(ext_graph[:tip_x].meet(ext_graph[:tip_y]).head_digest)
        .to eq(ext_graph[:root].head_digest)
    end

    it "answers both bounds where the dominator meet answers the one bottleneck" do
      answer = ext_fan_in[:tip_left].causal_meets(ext_fan_in[:tip_right])
      expect(answer).to eq(digests(ext_fan_in, :left, :right))
      expect(ext_fan_in[:tip_left].dominator_meet(ext_fan_in[:tip_right]).head_digest)
        .to eq(ext_fan_in[:b].head_digest)
      expect(answer).not_to include(ext_fan_in[:b].head_digest)
    end

    # The fixture above is the one that separates this operator from the
    # dominator meet by a NAMED INTERIOR event rather than by a root, so leaving
    # it unpinned against Ruby would leave exactly the distinction this spec
    # exists for resting on the Rust side alone.
    it "answers the digests the Ruby timeline answers where the bounds are two" do
      expect(ext_fan_in.transform_values(&:head_digest))
        .to eq(ruby_fan_in.transform_values(&:head_digest))
      expect(ext_fan_in[:tip_left].causal_meets(ext_fan_in[:tip_right]))
        .to eq(ruby_fan_in[:tip_left].causal_meets(ruby_fan_in[:tip_right]))
    end

    # Digest order is the one canonical order incomparable elements admit, so it
    # is part of the contract rather than an implementation accident.
    it "answers digests in digest order" do
      answer = ext_graph[:tip_x].causal_meets(ext_graph[:tip_y])
      expect(answer).to eq(answer.sort)
    end

    it "answers an Array of digest Strings, not a Timeline" do
      answer = ext_graph[:tip_x].causal_meets(ext_graph[:tip_y])
      expect(answer).to be_an(Array)
      expect(answer).to all(be_a(String))
    end

    # Asserted over the three-element answer on purpose: an empty Array is
    # deeply frozen for reasons that say nothing about the digests inside one.
    it "answers a deeply frozen array" do
      expect(ext_graph[:tip_x].causal_meets(ext_graph[:tip_y])).to be_deeply_frozen
    end

    it "answers nothing for heads sharing no causal history" do
      expect(ext_graph[:tip_x].causal_meets(say(ext_empty, "stranger"))).to eq([])
    end

    it "answers nothing exactly where the Ruby timeline answers nothing" do
      expect(ext_graph[:tip_x].causal_meets(say(ext_empty, "stranger")))
        .to eq(ruby_graph[:tip_x].causal_meets(say(ruby_empty, "stranger")))
    end

    it "answers a deeply frozen array when it answers nothing" do
      expect(ext_graph[:tip_x].causal_meets(say(ext_empty, "stranger"))).to be_deeply_frozen
    end

    it "answers nothing for the empty timeline from either side" do
      expect(ext_graph[:tip_x].causal_meets(ext_empty)).to eq([])
      expect(ext_empty.causal_meets(ext_graph[:tip_x])).to eq([])
    end

    it "refuses a question across two stores" do
      expect { ext_graph[:tip_x].causal_meets(elsewhere) }
        .to raise_error(described_class::CrossStore)
    end

    it "refuses it with the Ruby timeline's own message" do
      expect(cross_store_message(ext_graph[:tip_x], elsewhere))
        .to eq(cross_store_message(ruby_graph[:tip_x], Lain::Timeline.empty))
    end
  end
end
