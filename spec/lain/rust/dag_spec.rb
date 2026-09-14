# frozen_string_literal: true

# The three orders over one Rust store, named from Ruby: render ancestry and
# dominance are meet-semilattices, causal ancestry answers a set of maximal
# lower bounds. Each order is a class holding no state, handed two timelines as
# elements -- the same answers the timeline's own bindings give, because both
# routes reach one generic function per operation.
#
# The answers are fixed by the fixture's shape, not by a second implementation:
# every expectation below names the head it must land on.
RSpec.describe Lain::Ext::Dag do
  let(:store) { Lain::Ext::Store.new }
  let(:empty) { Lain::Ext::Timeline.empty(store:) }
  let(:graph) { bottleneck(empty) }
  let(:elsewhere) { Lain::Ext::Timeline.empty(store: Lain::Ext::Store.new) }
  let(:refusal) { "cannot compare Timelines backed by different stores" }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, causal: [])
    from.commit(role: :user, content: text(body), causal_parents: causal)
  end

  # `a -> b`, b forking to `left` and `right`, two tips that each render off one
  # fork while causally folding the other, a fresh root causally anchored at `b`,
  # and a stranger sharing nothing. The tips' render meet and dominator meet are
  # both `b`; their causal bounds are `left` and `right`, neither above the
  # other. `adopted` shares no render history with `left` but every path to
  # either runs through `b`, which is where the two semilattice orders part.
  def bottleneck(empty)
    b = say(say(empty, "a"), "b")
    left = say(b, "left")
    right = say(b, "right")
    { b:, left:, right:,
      tip_left: say(left, "tip_left", causal: [right.head_digest]),
      tip_right: say(right, "tip_right", causal: [left.head_digest]),
      adopted: say(empty, "adopted", causal: [b.head_digest]),
      stranger: say(empty, "stranger") }
  end

  def digests(*names) = names.map { |name| graph.fetch(name).head_digest }.sort

  describe "the timeline bindings" do
    it "meets on render ancestry" do
      expect(graph[:tip_left].meet(graph[:tip_right])).to eq(graph[:b])
      expect(graph[:tip_left] & graph[:tip_right]).to eq(graph[:b])
      expect(graph[:adopted].meet(graph[:left])).to eq(empty)
      expect(graph[:tip_left].meet(graph[:stranger])).to eq(empty)
    end

    it "orders on render ancestry" do
      expect(graph[:left].ancestor_of?(graph[:tip_left])).to be(true)
      expect(graph[:tip_left].ancestor_of?(graph[:left])).to be(false)
      expect(empty.ancestor_of?(graph[:stranger])).to be(true)
    end

    it "meets on dominance" do
      expect(graph[:tip_left].dominator_meet(graph[:tip_right])).to eq(graph[:b])
      expect(graph[:adopted].dominator_meet(graph[:left])).to eq(graph[:b])
      expect(graph[:tip_left].dominator_meet(graph[:stranger])).to eq(empty)
    end

    it "orders on dominance" do
      expect(graph[:b].dominates?(graph[:tip_left])).to be(true)
      expect(graph[:left].dominates?(graph[:tip_left])).to be(false)
      expect(empty.dominates?(graph[:stranger])).to be(true)
    end

    it "answers every maximal causal lower bound" do
      expect(graph[:tip_left].causal_meets(graph[:tip_right])).to eq(digests(:left, :right))
      expect(graph[:tip_left].causal_meets(graph[:stranger])).to eq([])
    end

    %i[meet & ancestor_of? dominator_meet dominates? causal_meets].each do |binding|
      it "refuses #{binding} across two stores, in the words it always has" do
        expect { graph[:tip_left].public_send(binding, elsewhere) }
          .to raise_error(Lain::Ext::Timeline::CrossStore, refusal)
      end
    end
  end

  describe Lain::Ext::Dag::RenderAncestry do
    it "meets as the timeline binding does, where dominance would answer otherwise" do
      expect(described_class.meet(graph[:adopted], graph[:left]))
        .to eq(graph[:adopted].meet(graph[:left]))
        .and eq(empty)
    end

    it "orders as the timeline binding does" do
      expect(described_class.below?(graph[:left], graph[:tip_left])).to be(true)
      expect(described_class.below?(graph[:tip_left], graph[:left])).to be(false)
    end
  end

  describe Lain::Ext::Dag::Dominance do
    it "meets as the timeline binding does" do
      expect(described_class.meet(graph[:adopted], graph[:left]))
        .to eq(graph[:adopted].dominator_meet(graph[:left]))
        .and eq(graph[:b])
    end

    it "orders as the timeline binding does" do
      expect(described_class.below?(graph[:b], graph[:tip_left])).to be(true)
      expect(described_class.below?(graph[:left], graph[:tip_left])).to be(false)
    end
  end

  describe Lain::Ext::Dag::CausalAncestry do
    it "answers the bounds the timeline binding does" do
      expect(described_class.meets(graph[:tip_left], graph[:tip_right]))
        .to eq(graph[:tip_left].causal_meets(graph[:tip_right]))
        .and eq(digests(:left, :right))
    end

    it "offers no meet, having no greatest lower bound to give" do
      expect(described_class).not_to respond_to(:meet)
    end
  end

  { Lain::Ext::Dag::RenderAncestry => %i[meet below?],
    Lain::Ext::Dag::Dominance => %i[meet below?],
    Lain::Ext::Dag::CausalAncestry => %i[meets] }.each do |order, questions|
    questions.each do |question|
      it "refuses #{order}.#{question} across two stores, in the timeline's words" do
        expect { order.public_send(question, graph[:tip_left], elsewhere) }
          .to raise_error(Lain::Ext::Timeline::CrossStore, refusal)
        expect { order.public_send(question, elsewhere, graph[:tip_left]) }
          .to raise_error(Lain::Ext::Timeline::CrossStore, refusal)
      end
    end
  end
end
