# frozen_string_literal: true

# Spans and doubles, built by a module rather than by `let`s because half of
# this file's subjects are built in a GROUP BODY: `include_examples` runs there,
# and a config Hash written there closes over `self` = the example group, where
# no `let` exists yet.
module StrategyFixtures
  module_function

  def message(body, role: "user") = { "role" => role, "content" => [{ "type" => "text", "text" => body }] }

  # Alternating, so a span reads as a real conversation slice.
  def span(size) = Array.new(size) { |i| message(("a".."z").to_a.sample, role: i.even? ? "user" : "assistant") }

  # Sizes are fixed and contents are random: the laws quantify over the spans,
  # and a random SIZE could draw five empty spans and certify nothing.
  def spans = [0, 1, 2, 3, 5].map { |size| span(size) }

  # `[m, other, m]`: rewritten by any of these strategies, length-preserving
  # under a per-message map, and repeating an element -- the three conditions
  # spec/support/shared_examples/elementwise.rb's `judged` guard reads.
  def repeating
    repeated = message("a")
    [[repeated, message("b", role: "assistant"), repeated]]
  end

  # A strategy that proposes a fixed list of ranges. The well-formedness
  # examples are about what the seam does with a proposal, never about how one
  # is computed.
  def answering(ranges)
    Class.new(Lain::Compaction::Strategy::Base) do
      define_method(:propose_ranges) { |_messages, **| ranges }
    end.new.freeze
  end

  # Elementwise and unconditional: #blocks is the concatenation of a per-message
  # map that knows only its own message, and #collapse is inherited -- Elide's
  # shape.
  def marking
    Class.new(Lain::Compaction::Strategy::Base) do
      def blocks(messages) = messages.flat_map { |message| marked(message) }

      private

      def marked(message) = [{ "type" => "text", "text" => "<#{message.fetch("role")}>" }]
    end.new.freeze
  end

  # Pure and NOT elementwise: a tally is a function of the whole span, so no map
  # over elements can produce it. This is the shape behind both negatives -- the
  # homomorphism one and the elementwise battery's. The two helpers that look
  # unused are the knobs that battery is handed, since a refutation needs
  # SOMETHING to hold the operation to.
  def tallying
    Class.new(Lain::Compaction::Strategy::Base) do
      def blocks(messages) = [{ "type" => "text", "text" => "#{messages.size} messages" }]

      def whole_span(_span) = :nothing

      private

      def per_message(message, _analysis) = [{ "type" => "text", "text" => message.fetch("role") }]
    end.new.freeze
  end

  # Reachable mutable state, which is what the purity laws' shareability proxy
  # is a proxy FOR: the shape a strategy holding an oracle has.
  module Tally
    def initialize
      super
      @seen = []
    end
  end

  # Elementwise and NOT pure: it holds a mutable tally, so it is not
  # `Ractor.shareable?`. The tally never enters a per-message image, so the map
  # is still a homomorphism -- which is the point: the axes are independent.
  def counting
    Class.new(Lain::Compaction::Strategy::Base) do
      include Tally

      def blocks(messages) = messages.flat_map { |message| counted(message) }

      private

      def counted(message) = [{ "type" => "text", "text" => "<#{message.fetch("role")}>" }]
    end.new
  end

  def elementwise_battery(strategy, each:, analysis: nil)
    AlgebraLaws::Elementwise.from(instance: -> { strategy }, spans: -> { repeating },
                                  operation: :blocks, each:, analysis:)
  end

  def purity_battery(strategy)
    AlgebraLaws::Pure.from(instance: -> { strategy }, operation: :blocks, population: -> { spans })
  end

  # The one span every composition law is read over, and the four zones it
  # divides into. Four because the widest law in the group -- associativity --
  # draws THREE times, so any three consecutive draws have to be three
  # different zones; a cycle of three would hand associativity `a | a` on every
  # third iteration.
  COMPOSITION_SPAN = 0..15
  ZONE = 4
  ZONES = 4

  # == Why the population is a fixed cycle of zone-disjoint strategies
  #
  # `#|` is PARTIAL -- two strategies whose ranges overlap refuse, and `a | a`
  # always overlaps -- while the shared monoid group draws its population
  # through a NULLARY `generator` called independently per law, up to three
  # times in one check. "Draw a disjoint pair" is therefore not expressible as a
  # filter over an already-built pool: nothing downstream of the generator can
  # see the other draws.
  #
  # So the pool is built disjoint instead. Four strategies, each owning one
  # quarter of COMPOSITION_SPAN and proposing a real range inside it, handed out
  # in a fixed cycle: any three consecutive draws are three different zones, so
  # no law is given an overlapping pair or `a | a`. The zones carry NON-EMPTY
  # range-sets, so the laws are read over a composition that composes
  # something -- an all-Identity pool would satisfy every law about nothing.
  #
  # And no draw is built THROUGH `#|`: a population produced by the operation
  # under test collapses along with it, and the laws then hold vacuously. Break
  # `#|` in any way at all and these four are untouched -- a left-absorbing `#|`
  # answers only the left operand's zone, which commutativity reads as
  # different ranges out and fails.
  def composition
    drawn = Array.new(ZONES) { |zone| zoned(zone) }.cycle
    { operation: ->(a, b) { a | b }, generator: -> { drawn.next }, equal: observationally_equal }
  end

  # One zone's worth of one span, collapsed to a marker naming the zone. The
  # range stops one index short of its zone so consecutive zones are separated
  # by a retained index rather than merely adjacent -- adjacency is legal, and
  # an off-by-one that merged two zones would then be invisible.
  def zoned(zone)
    first = zone * ZONE
    Class.new(Lain::Compaction::Strategy::Base) do
      define_method(:name) { -"zone #{zone}" }
      define_method(:propose_ranges) { |_messages, **| [first..(first + ZONE - 2)] }
      define_method(:blocks) { |_messages| [{ "type" => "text", "text" => "<zone #{zone}>" }] }
    end.new.freeze
  end

  # Two composed strategies are never `==` as objects, so equality is
  # OBSERVATIONAL, and over both halves of the seam: the ranges answered over
  # one span AND what each collapses to. Ranges alone would leave the dispatch
  # unread, which is the half `a | Identity` collapsing exactly as `a` turns on.
  def observationally_equal
    probe = Array.new(COMPOSITION_SPAN.size) { |index| message("m#{index}") }
    observe = lambda do |strategy|
      strategy.ranges(probe, span: COMPOSITION_SPAN).map do |range|
        [range.first, range.max, strategy.collapse(probe[range], range:).content]
      end
    end
    ->(a, b) { observe.call(a) == observe.call(b) }
  end
end

RSpec.describe Lain::Compaction::Strategy do
  let(:span) { StrategyFixtures.span(4) }

  describe "the seam every strategy answers" do
    it "refuses both hooks loudly, naming the strategy" do
      stub_const("Silent", Class.new(described_class::Base))

      expect { Silent.new.ranges(span, span: 0..3) }.to raise_error(NotImplementedError, /Silent/)
      expect { Silent.new.collapse(span) }.to raise_error(NotImplementedError, /Silent/)
    end

    it "offers no whole-array rewrite, which would bypass the range discipline" do
      expect(described_class::Base.new).not_to respond_to(:call)
    end

    it "names an anonymous strategy with a frozen, shareable name" do
      expect(Class.new(described_class::Base).new.name).to be_deeply_frozen
    end
  end

  describe "the two questions Base answers for every strategy" do
    it "refuses a subclass that redefines the validated ranges, naming the hook to write" do
      expect { Class.new(described_class::Base) { def ranges(_messages, span:) = [span] } }
        .to raise_error(Lain::Error, /propose_ranges/)
    end

    it "refuses a subclass that redefines the collapse, naming what to write" do
      expect { Class.new(described_class::Base) { def collapse(_messages) = "not a Replacement" } }
        .to raise_error(Lain::Error, /blocks/)
    end

    # The `define_method` door: it fires `method_added` exactly as `def` does.
    it "refuses a collapse written by define_method, naming what to write" do
      expect { Class.new(described_class::Base) { define_method(:collapse) { |_messages| [] } } }
        .to raise_error(Lain::Error, /blocks/)
    end

    it "still allows the hooks, and a hand-written blocks over the inherited collapse" do
      expect { StrategyFixtures.marking }.not_to raise_error
      expect(StrategyFixtures.marking.blocks(span).size).to eq(span.size)
    end

    # `method_added` fires for every `def`-shaped door, but it structurally
    # cannot see module composition: an `include`d or `prepend`ed module that
    # defines #collapse, or a `define_singleton_method`, never reaches it. That
    # is not the door a strategy is invited through, but a shared mixin is the
    # obvious next refactor. Ownership catches every door at once, including
    # the three the hook cannot, so this assertion is the seal and the hook is
    # only the early, better-worded half of it. Every strategy in lib/ is
    # named, plus the doubles here: nothing enumerates strategies for us.
    it "keeps both questions owned by Base, whatever a strategy includes" do
      strategies = [described_class::Identity, described_class::Base, described_class::Elide,
                    described_class::ElideToolObservations, described_class::Summarizing,
                    described_class::SummarizeConversation, described_class::Composed,
                    StrategyFixtures.marking.class, StrategyFixtures.tallying.class,
                    StrategyFixtures.counting.class]

      questions = %i[ranges collapse]
      owners = strategies.flat_map do |subject|
        questions.map { |question| subject.instance_method(question).owner }
      end

      expect(owners.uniq).to eq([described_class::Base])
    end
  end

  describe "the identity strategy" do
    let(:identity) { described_class::Identity.new }

    it "collapses nothing" do
      expect(identity.propose_ranges(span, span: 0..3)).to be_empty
      expect(identity.ranges(span, span: 0..3)).to be_empty
    end

    it "is a deeply frozen, shareable value" do
      expect(identity).to be_deeply_frozen
    end
  end

  describe "the ranges a strategy proposes" do
    it "answers a well-formed partition unchanged, adjacency included" do
      expect(StrategyFixtures.answering([0..1, 2..3]).ranges(span, span: 0..3)).to eq([0..1, 2..3])
    end

    it "refuses one outside the span, naming the range and the span" do
      expect { StrategyFixtures.answering([0..1, 7..9]).ranges(span, span: 0..3) }
        .to raise_error(described_class::NotAPartition, /7\.\.9.*0\.\.3/)
    end

    it "refuses two that overlap, naming the overlap" do
      expect { StrategyFixtures.answering([0..2, 1..3]).ranges(span, span: 0..3) }
        .to raise_error(described_class::NotAPartition, /overlap/)
    end

    it "refuses them out of ascending order, naming the ordering" do
      expect { StrategyFixtures.answering([2..3, 0..1]).ranges(span, span: 0..3) }
        .to raise_error(described_class::NotAPartition, /ascending order/)
    end

    # Both are inside the span by every reading, so calling them "outside" sent a
    # reader looking for a bounds bug that was not there.
    it "refuses an empty range as empty rather than as out of bounds" do
      [2..1, 2...2].each do |hollow|
        expect { StrategyFixtures.answering([hollow]).ranges(span, span: 0..3) }
          .to raise_error(described_class::NotAPartition, /an empty range/)
      end
    end

    it "refuses something that is not a Range at all, saying so" do
      [[[0, 1]], [nil]].each do |proposal|
        expect { StrategyFixtures.answering(proposal).ranges(span, span: 0..3) }
          .to raise_error(described_class::NotAPartition, /not a Range/)
      end
    end
  end

  describe "the blocks a strategy answers" do
    it "refuses a bare Hash where an Array of blocks was meant, naming the strategy" do
      stub_const("Bareheaded", Class.new(described_class::Base) do
        def blocks(_messages) = { "type" => "text", "text" => "x" }
      end)

      expect { Bareheaded.new.collapse(span) }.to raise_error(described_class::NotBlocks, /Bareheaded/)
    end

    it "refuses nil, rather than dying on it further down" do
      stub_const("Silentish", Class.new(described_class::Base) { def blocks(_messages) = nil })

      expect { Silentish.new.collapse(span) }.to raise_error(described_class::NotBlocks, /Silentish/)
    end
  end

  # Elementwise and pure are independent axes, and each is a matter of what
  # `#blocks` DOES: the batteries read the operation, and nothing a class says
  # about itself enters into it.
  describe "the two algebraic axes" do
    it "is elementwise but not pure when it holds a tally the map never reads" do
      counting = StrategyFixtures.counting

      expect(AlgebraLaws.outcomes(StrategyFixtures.elementwise_battery(counting, each: :counted)).values.uniq)
        .to eq([:holds])
      expect(AlgebraLaws.outcomes(StrategyFixtures.purity_battery(counting)))
        .to include("reaches no mutable state" => :fails)
    end

    it "is pure but not elementwise when it answers a function of the whole span" do
      tallying = StrategyFixtures.tallying
      battery = StrategyFixtures.elementwise_battery(tallying, each: :per_message, analysis: :whole_span)
      refuted = AlgebraLaws.outcomes(battery)

      expect(AlgebraLaws.outcomes(StrategyFixtures.purity_battery(tallying)).values.uniq).to eq([:holds])
      expect(refuted).to include("concatenates its per-element map against the whole-span analysis" => :fails)
      expect(refuted.values.grep(Exception)).to be_empty
    end

    it "offers the elementwise battery something to read, on the same spans" do
      battery = StrategyFixtures.elementwise_battery(StrategyFixtures.marking, each: :marked)

      expect([battery.rewritten.empty?, battery.judged.empty?]).to eq([false, false])
    end
  end

  describe "an elementwise strategy, held to the homomorphism law" do
    strategy = StrategyFixtures.marking
    drawn = StrategyFixtures.spans

    include_examples "a monoid homomorphism",
                     collapse: ->(messages) { strategy.collapse(messages) },
                     unit: Lain::Compaction::Strategy::DROP,
                     spans: -> { drawn }
  end

  describe "a whole-span strategy, held to the negative" do
    strategy = StrategyFixtures.tallying
    drawn = StrategyFixtures.spans

    include_examples "not a monoid homomorphism",
                     collapse: ->(messages) { strategy.collapse(messages) },
                     unit: Lain::Compaction::Strategy::DROP,
                     spans: -> { drawn }
  end

  describe "a pure strategy, held to the purity laws" do
    strategy = StrategyFixtures.tallying

    include_examples "a pure operation",
                     instance: -> { strategy },
                     operation: :blocks,
                     population: -> { StrategyFixtures.spans }
  end

  # Identity proposes no ranges whatever it is offered, so what the purity laws
  # read is the shareability proxy and the absence of any reachable state --
  # the whole claim for a Null Object. The population is drawn fresh per law,
  # so one law cannot read arguments another has already been through.
  describe "the identity strategy, held to the purity laws on #propose_ranges" do
    identity = described_class::Identity.new

    include_examples "a pure operation",
                     instance: -> { identity },
                     operation: :propose_ranges,
                     population: -> { StrategyFixtures.spans },
                     keywords: ->(span) { { span: 0..[span.size - 1, 0].max } }
  end

  # The fold the compaction flag resolves a `+`-joined name through: a
  # commutative monoid whose unit is the Identity strategy.
  describe "the composition monoid on #|" do
    include_examples "a monoid", identity: described_class::Identity.new, **StrategyFixtures.composition

    include_examples "a commutative monoid", **StrategyFixtures.composition
  end

  describe "the replacement a collapse answers" do
    let(:content) { [{ "type" => "text", "text" => "a summary" }] }
    let(:replacement) { described_class::Replacement.new(content:) }

    it "exposes content only, with no role to read and none to set" do
      expect(described_class::Replacement.members).to eq(%i[content])
      expect(replacement).not_to respond_to(:role)
      expect { replacement.with(role: "user") }.to raise_error(ArgumentError, /role/)
    end

    it "refuses empty content, which renders as a block the provider rejects" do
      expect { described_class::Replacement.new(content: []) }.to raise_error(described_class::Blank)
    end

    # Anthropic rejects the request if ANY text block is empty, so an all-blank
    # reading let `[blank, good]` through.
    it "refuses a blank text block even beside a good one" do
      [[{ "type" => "text", "text" => "   " }],
       [{ "type" => "text", "text" => "" }, { "type" => "text", "text" => "kept" }],
       [{ "type" => "text", "text" => "kept" }, { "type" => "text", "text" => "\t\n" }]].each do |blank|
        expect { described_class::Replacement.new(content: blank) }.to raise_error(described_class::Blank)
      end
    end

    it "refuses content that is not content blocks" do
      ["hi", [nil], [{}], ["hi"], { "type" => "text", "text" => "x" },
       [nil, { "type" => "text", "text" => "kept" }],
       [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]].each do |foreign|
        expect { described_class::Replacement.new(content: foreign) }
          .to raise_error(described_class::NotBlocks)
      end
    end

    it "keeps a block that carries no text at all" do
      block = [{ "type" => "tool_use", "id" => "toolu_0", "name" => "search", "input" => {} }]

      expect(described_class::Replacement.new(content: block).content).to eq(block)
    end

    it "distinguishes DROP, a singleton carrying no content" do
      drop = described_class::DROP

      expect(drop).not_to eq(replacement)
      expect([drop.drop?, replacement.drop?]).to eq([true, false])
      expect(drop.content).to be_empty
    end

    it "answers DROP rather than a blank replacement for no blocks at all" do
      expect(described_class::Replacement.of([])).to be(described_class::DROP)
    end

    it "is a deeply frozen, shareable value that leaves its caller's blocks alone" do
      mutable = [{ "type" => "text", "text" => +"a summary" }]
      built = described_class::Replacement.new(content: mutable)

      expect(built).to be_deeply_frozen
      expect(built.content.first["text"]).to be_frozen
      expect(mutable.first["text"]).not_to be_frozen
    end
  end
end
