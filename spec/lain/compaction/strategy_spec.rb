# frozen_string_literal: true

# Spans and doubles, built by a module rather than by `let`s because half of
# this file's subjects are built in a GROUP BODY: `include_examples` runs there,
# and a config Hash written there closes over `self` = the example group, where
# no `let` exists yet. spec/support/algebra_generators.rb documents the same rule
# and answers it the same way.
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

  # Elementwise and unconditional -- {Lain::Algebra::Elementwise::Alone} -- so it
  # writes ONLY its per-message map and inherits both the span map and #collapse.
  # This is T7's shape. Declared against a scratch registry:
  # {Lain::Algebra.registry} is process-wide and spec/algebra_laws_spec.rb
  # asserts that every generator answers a declaration somebody makes, so an
  # anonymous double declaring against the global one goes red in that file, not
  # this one.
  def marking(registry)
    Class.new(Lain::Compaction::Strategy::Base) do
      include Lain::Algebra::Elementwise
      include Lain::Algebra::Pure

      private

      def marked(message) = [{ "type" => "text", "text" => "<#{message.fetch("role")}>" }]

      elementwise(on: :blocks, each: :marked, registry:)
      pure(on: :blocks, registry:)
    end.new.freeze
  end

  # Pure and NOT elementwise: a tally is a function of the whole span, so no map
  # over elements can produce it. T6's shape, and the subject of both negatives
  # -- the homomorphism one and the registry refutation of :elementwise. The two
  # helpers that look unused are the knobs a refutation's generator must supply,
  # since a battery needs SOMETHING to hold the claim to.
  def tallying(registry)
    Class.new(Lain::Compaction::Strategy::Base) do
      include Lain::Algebra::Pure

      def blocks(messages) = [{ "type" => "text", "text" => "#{messages.size} messages" }]

      def whole_span(_span) = :nothing

      private

      def per_message(message, _analysis) = [{ "type" => "text", "text" => message.fetch("role") }]

      pure(on: :blocks, registry:)
    end.new.freeze
  end

  # Reachable mutable state, which is what {Lain::Algebra::Pure}'s shareability
  # proxy is a proxy FOR: the shape a strategy holding an oracle has.
  module Tally
    def initialize
      super
      @seen = []
    end
  end

  # Elementwise and NOT pure: it holds a mutable tally, so it is not
  # `Ractor.shareable?`, and it declares no purity. The tally never enters a
  # per-message image, so the map is still a homomorphism -- which is the point:
  # the axes are independent.
  def counting(registry)
    Class.new(Lain::Compaction::Strategy::Base) do
      include Lain::Algebra::Elementwise
      include Lain::Algebra::Pure
      include Tally

      private

      def counted(message) = [{ "type" => "text", "text" => "<#{message.fetch("role")}>" }]

      elementwise(on: :blocks, each: :counted, registry:)
    end.new
  end
end

RSpec.describe Lain::Compaction::Strategy do
  let(:registry) { Lain::Algebra::Registry.new }
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
        .to raise_error(described_class::Sealed, /propose_ranges/)
    end

    it "refuses a subclass that redefines the collapse, naming what to write" do
      expect { Class.new(described_class::Base) { def collapse(_messages) = "not a Replacement" } }
        .to raise_error(described_class::Sealed, /blocks/)
    end

    # The natural typo, and the one that used to pass in silence: the card's own
    # duck section names #collapse, and Algebra::Elementwise only refuses
    # generating over a method the class wrote ITSELF.
    it "refuses an elementwise declaration aimed at the collapse rather than the blocks" do
      scratch = registry

      expect do
        Class.new(described_class::Base) do
          include Lain::Algebra::Elementwise

          private

          def attested(_message) = [{ "type" => "text", "text" => "x" }]

          elementwise(on: :collapse, each: :attested, registry: scratch)
        end
      end.to raise_error(described_class::Sealed, /blocks/)
    end

    it "still allows the hooks, and generating over the inherited blocks" do
      expect { StrategyFixtures.marking(registry) }.not_to raise_error
      expect(StrategyFixtures.marking(registry).blocks(span).size).to eq(span.size)
    end

    # `method_added` fires for every `def`-shaped door, but it structurally
    # cannot see module composition: an `include`d or `prepend`ed module that
    # defines #collapse, or a `define_singleton_method`, never reaches it. That
    # is not the door the card invites -- but T7 is told to `include` two
    # modules, so composition IS the idiom here and a shared mixin is the
    # obvious next refactor. Ownership catches every door at once, including
    # the three the hook cannot, so this assertion is the seal and the hook is
    # only the early, better-worded half of it.
    it "keeps both questions owned by Base, whatever a strategy includes" do
      strategies = [described_class::Identity, described_class::Base,
                    StrategyFixtures.marking(registry).class,
                    StrategyFixtures.tallying(registry).class,
                    StrategyFixtures.counting(registry).class,
                    *Lain::Algebra.registry.map(&:subject)]

      sealed = strategies.uniq.select { |subject| subject.is_a?(Class) && subject <= described_class::Base }
      questions = %i[ranges collapse]
      owners = sealed.flat_map do |subject|
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

  describe "the two algebraic axes" do
    it "answers them independently" do
      elementwise_only = StrategyFixtures.counting(registry)
      pure_only = StrategyFixtures.tallying(registry)

      expect([elementwise_only.is_a?(Lain::Algebra::Elementwise), elementwise_only.pure?(:blocks, registry:)])
        .to eq([true, false])
      expect([pure_only.is_a?(Lain::Algebra::Elementwise), pure_only.pure?(:blocks, registry:)])
        .to eq([false, true])
    end

    it "reads elementwise-ness off the module, with no second declaration to drift" do
      expect(StrategyFixtures.marking(registry)).to be_a(Lain::Algebra::Elementwise)
      expect(StrategyFixtures.tallying(registry)).not_to be_a(Lain::Algebra::Elementwise)
      expect(described_class::Base.instance_methods.grep(/elementwise|homomorph/)).to be_empty
    end
  end

  # The group the REGISTRY SWEEP judges every :elementwise claim by -- a
  # different file from the homomorphism group below, and the one that decides
  # whether T7's declaration and T6's refutation can be swept at all. It was
  # hardcoded to `instance.call(span)`, and this seam has no #call by design.
  describe "the elementwise battery the registry sweep judges strategies by" do
    def battery(strategy, each:, operation: :blocks, analysis: nil)
      AlgebraLaws::Elementwise.from(instance: -> { strategy }, spans: -> { StrategyFixtures.repeating },
                                    operation:, each:, analysis:)
    end

    def outcomes(battery)
      battery.to_h.transform_values do |law|
        law.call ? :holds : :fails
      rescue StandardError => e
        e.class
      end
    end

    it "proves an unconditional declaration made on the seam's own operation" do
      declared = battery(StrategyFixtures.marking(registry), each: :marked)

      expect(outcomes(declared).values.uniq).to eq([:holds])
    end

    it "reads the operation the registry recorded, rather than one assumed by name" do
      StrategyFixtures.marking(registry)

      expect(registry.declarations.map { |entry| [entry.operation, entry.analysis] }).to include([:blocks, nil])
    end

    it "confirms a whole-span refutation by a law that fails rather than raises" do
      refuted = outcomes(battery(StrategyFixtures.tallying(registry), each: :per_message, analysis: :whole_span))

      expect(refuted).to include("concatenates its per-element map against the whole-span analysis" => :fails)
      expect(refuted.values.uniq - %i[holds fails]).to be_empty
    end

    it "gives the declaration's own guards something to read, on the same spans" do
      declared = battery(StrategyFixtures.marking(registry), each: :marked)

      expect([declared.rewritten.empty?, declared.judged.empty?]).to eq([false, false])
    end
  end

  describe "an elementwise strategy, held to the homomorphism law" do
    strategy = StrategyFixtures.marking(Lain::Algebra::Registry.new)
    drawn = StrategyFixtures.spans

    include_examples "a monoid homomorphism",
                     collapse: ->(messages) { strategy.collapse(messages) },
                     unit: Lain::Compaction::Strategy::DROP,
                     spans: -> { drawn }
  end

  describe "a whole-span strategy, held to the negative" do
    strategy = StrategyFixtures.tallying(Lain::Algebra::Registry.new)
    drawn = StrategyFixtures.spans

    include_examples "not a monoid homomorphism",
                     collapse: ->(messages) { strategy.collapse(messages) },
                     unit: Lain::Compaction::Strategy::DROP,
                     spans: -> { drawn }
  end

  describe "a pure strategy, held to the purity laws" do
    strategy = StrategyFixtures.tallying(Lain::Algebra::Registry.new)

    include_examples "a pure operation",
                     instance: -> { strategy },
                     operation: :blocks,
                     population: -> { StrategyFixtures.spans }
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
    # reading let `[blank, good]` through -- and `+` then propagated it.
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

    it "concatenates under DROP as its unit, answering the operand itself" do
      expect(described_class::DROP + replacement).to be(replacement)
      expect(replacement + described_class::DROP).to be(replacement)
      expect((replacement + replacement).content).to eq(content + content)
    end

    # The fold `#+` invites -- `inject(:+)` over a span's replacements -- used to
    # deep-copy the whole accumulated content at every step.
    it "copies nothing when folding replacements whose content is already shareable" do
      folded = Array.new(4) { |i| described_class::Replacement.text("block #{i}") }
                    .inject(described_class::DROP, :+)

      expect(folded.content.size).to eq(4)
      expect(folded).to be_deeply_frozen
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
