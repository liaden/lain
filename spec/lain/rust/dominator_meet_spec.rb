# frozen_string_literal: true

# The checkpoint primitive on the Rust timeline -- the deepest common dominator
# over the UNION graph (render and causal edges together, under a virtual root)
# -- and the dominance order that meet is taken over.
#
# Ruby is the oracle. Every answer below is compared against
# `Lain::Timeline#dominator_meet` and `Lain::Timeline::Dominators#dominates?`
# over the same graph, and "the same graph" is not an assumption: both
# implementations are driven through the identical sequence of public calls, and
# content addressing makes the resulting digests equal -- which the first
# example asserts before comparing any meet.
RSpec.describe Lain::Ext::Timeline do
  let(:store) { Lain::Ext::Store.new }
  let(:ext_empty) { described_class.empty(store:) }
  let(:ruby_empty) { Lain::Timeline.empty }
  let(:ext_graph) { bottleneck(ext_empty) }
  let(:ruby_graph) { bottleneck(ruby_empty) }
  let(:ext_bypass) { bypass(ext_empty) }
  let(:ruby_bypass) { bypass(ruby_empty) }
  let(:elsewhere) { described_class.empty(store: Lain::Ext::Store.new) }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, causal: [])
    from.commit(role: :user, content: text(body), causal_parents: causal)
  end

  # `a -> b`, b forking to `left` and `right`, and two tips that each render off
  # one fork while causally folding the other. Every path from the virtual root
  # to either tip runs through `b`, so `b` is the deepest common dominator --
  # while `left` and `right` are common ancestors that dominate neither tip.
  # One shape, both questions.
  #
  # Takes an empty timeline rather than building one, so the same calls grow the
  # same graph on either implementation.
  def bottleneck(empty)
    b = say(say(empty, "a"), "b")
    left = say(b, "left")
    right = say(b, "right")
    { b:, left:, right:,
      tip_left: say(left, "tip_left", causal: [right.head_digest]),
      tip_right: say(right, "tip_right", causal: [left.head_digest]) }
  end

  # The bottleneck answers `b` under the union-graph meet AND under the
  # render-only one, so no example over it can tell the two operators apart --
  # wire `#dominator_meet` to the render meet and every bottleneck example here
  # stays green. This shape separates them: BOTH tips render off `left`, and
  # only `tip_right` folds `right` causally. The render meet is therefore
  # `left`, while the dominator meet is `b`, because the union-graph path
  # root -> b -> right -> tip_right bypasses `left` entirely.
  def bypass(empty)
    b = say(say(empty, "a"), "b")
    left = say(b, "left")
    right = say(b, "right")
    { b:, left:, right:,
      tip_left: say(left, "tip_left"),
      tip_right: say(left, "tip_right", causal: [right.head_digest]) }
  end

  # The refusal message from a real raise, so the two implementations' wording
  # can be compared byte for byte. Takes the operation because the two operators
  # here reach the same store check by different names.
  def cross_store_message(timeline, other, operation)
    timeline.public_send(operation, other)
    raise "expected a cross-store #{operation} to be refused"
  rescue Lain::Error => e
    e.message
  end

  describe "#dominator_meet" do
    it "grows the same graph on both implementations" do
      expect(ext_graph.transform_values(&:head_digest))
        .to eq(ruby_graph.transform_values(&:head_digest))
    end

    it "answers the digest the Ruby timeline answers" do
      expect(ext_graph[:tip_left].dominator_meet(ext_graph[:tip_right]).head_digest)
        .to eq(ruby_graph[:tip_left].dominator_meet(ruby_graph[:tip_right]).head_digest)
    end

    # What stops the parity above from agreeing on nothing: the answer is a
    # named event, and it is the bottleneck rather than either fork -- so this
    # is the dominator meet and not the deepest common ancestor.
    it "answers the bottleneck, not either fork" do
      meet = ext_graph[:tip_left].dominator_meet(ext_graph[:tip_right])
      expect(meet).to eq(ext_graph[:b])
      expect(meet).not_to eq(ext_graph[:left])
      expect(meet).not_to eq(ext_graph[:right])
    end

    # The bottleneck cannot separate this operator from the render meet -- both
    # answer `b` there -- so every example above it holds just as well for
    # `#meet`, and parity proven over that shape is parity about a distinction
    # the fixture cannot see. These two are what pin WHICH operator this is.
    it "answers the union-graph meet, not the render meet" do
      expect(ext_bypass[:tip_left].dominator_meet(ext_bypass[:tip_right])).to eq(ext_bypass[:b])
      expect(ext_bypass[:tip_left].meet(ext_bypass[:tip_right])).to eq(ext_bypass[:left])
    end

    it "answers what the Ruby timeline answers where the two operators disagree" do
      expect(ext_bypass.transform_values(&:head_digest))
        .to eq(ruby_bypass.transform_values(&:head_digest))
      expect(ext_bypass[:tip_left].dominator_meet(ext_bypass[:tip_right]).head_digest)
        .to eq(ruby_bypass[:tip_left].dominator_meet(ruby_bypass[:tip_right]).head_digest)
    end

    it "answers a timeline over the receiver's own store" do
      meet = ext_graph[:tip_left].dominator_meet(ext_graph[:tip_right])
      expect(meet).to be_a(described_class)
      expect(meet.store).to be(store)
    end

    it "answers the empty timeline, never the virtual root, for heads sharing no history" do
      stranger = say(ext_empty, "stranger")
      meet = ext_graph[:tip_left].dominator_meet(stranger)
      expect(meet).to be_empty
      expect(meet.head_digest).to be_nil
      expect(meet.head).to be_nil
    end

    it "answers empty exactly where the Ruby timeline answers empty" do
      expect(ext_graph[:tip_left].dominator_meet(say(ext_empty, "stranger")).empty?)
        .to eq(ruby_graph[:tip_left].dominator_meet(say(ruby_empty, "stranger")).empty?)
    end

    it "absorbs the empty timeline from either side" do
      expect(ext_graph[:tip_left].dominator_meet(ext_empty)).to be_empty
      expect(ext_empty.dominator_meet(ext_graph[:tip_left])).to be_empty
    end

    it "refuses a meet across two stores" do
      expect { ext_graph[:tip_left].dominator_meet(elsewhere) }
        .to raise_error(described_class::CrossStore)
    end

    it "refuses it with the Ruby timeline's own message" do
      expect(cross_store_message(ext_graph[:tip_left], elsewhere, :dominator_meet))
        .to eq(cross_store_message(ruby_graph[:tip_left], Lain::Timeline.empty, :dominator_meet))
    end
  end

  # The order the meet is taken over, and the reason it is exposed at all: the
  # fourth semilattice law says a meet sits BELOW both operands, and below means
  # dominated. `ancestor_of?` is strictly weaker -- it asks whether SOME path
  # arrives, dominance whether EVERY one does -- so a law checked with it passes
  # vacuously.
  describe "#dominates?" do
    it "answers false where render ancestry answers true" do
      expect(ext_graph[:left].ancestor_of?(ext_graph[:tip_left])).to be(true)
      expect(ext_graph[:left].dominates?(ext_graph[:tip_left])).to be(false)
    end

    it "agrees with the Ruby dominance predicate over every pair in the graph" do
      dominators = Lain::Timeline::Dominators.new(ruby_empty.store)
      answers = pairs { |a, b| ext_graph[a].dominates?(ext_graph[b]) }
      expect(answers)
        .to eq(pairs { |a, b| dominators.dominates?(ruby_graph[a].head_digest, ruby_graph[b].head_digest) })
      # Non-vacuous: a constant predicate would satisfy the equality above.
      expect(answers.values).to include(true).and include(false)
    end

    it "puts the empty timeline below everything and above only itself" do
      expect(ext_empty.dominates?(ext_graph[:tip_left])).to be(true)
      expect(ext_graph[:tip_left].dominates?(ext_empty)).to be(false)
      expect(ext_empty.dominates?(ext_empty)).to be(true)
    end

    it "is reflexive" do
      expect(ext_graph[:tip_left].dominates?(ext_graph[:tip_left])).to be(true)
    end

    it "refuses a question across two stores" do
      expect { ext_graph[:tip_left].dominates?(elsewhere) }
        .to raise_error(described_class::CrossStore)
    end

    # Symmetric with the meet's refusal above, because both reach the same
    # store check. Ruby exposes its dominance predicate on `Dominators`, which
    # takes bare digests and so asks no store question at all -- the wording
    # under comparison is `Timeline#same_store!`'s, one message for every
    # operator on either side, reached here through the Ruby meet.
    it "refuses it with the Ruby timeline's own message" do
      expect(cross_store_message(ext_graph[:tip_left], elsewhere, :dominates?))
        .to eq(cross_store_message(ruby_graph[:tip_left], Lain::Timeline.empty, :dominator_meet))
    end
  end

  # Every ordered pair of the bottleneck's named events, answered by the block.
  def pairs
    names = ext_graph.keys
    names.product(names).to_h { |a, b| [[a, b], yield(a, b)] }
  end
end
