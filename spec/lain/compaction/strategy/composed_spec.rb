# frozen_string_literal: true

# Strategy doubles and one history, built by a module rather than by `let`s for
# the reason spec/lain/compaction/strategy_spec.rb records: `include_examples`
# and several multi-history examples run in a group body, where no `let` exists.
#
# None of these doubles declares any algebra. {Lain::Algebra.registry} is
# process-wide and spec/algebra_laws_spec.rb asserts every declaration has a
# generator, so an anonymous class declaring against the global registry would
# go red there rather than here.
module ComposedFixtures
  module_function

  def text(body) = { "type" => "text", "text" => body }

  def message(body, role: "user") = { "role" => role, "content" => [text(body)] }

  def span(size) = Array.new(size) { |index| message("m#{index}", role: index.even? ? "user" : "assistant") }

  # Proposes a fixed list of ranges and collapses each to one marker naming
  # itself, so which strategy answered a given range is readable off the
  # derived content rather than inferred.
  def marking(label, ranges)
    Class.new(Lain::Compaction::Strategy::Base) do
      define_method(:name) { label }
      define_method(:propose_ranges) { |_messages, **| ranges }
      define_method(:blocks) { |messages| [{ "type" => "text", "text" => "<#{label} #{messages.size}>" }] }
    end.new.freeze
  end

  def tool_use(id) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => {} }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "ok" }

  # One conversational turn, two tool rounds, and two LONE conversational turns
  # between them -- the shape the motivating case needs. Roles alternate by
  # index, so a `tool_use` is always the assistant's and its answer always the
  # user's, exactly as spec/lain/compaction/derivation_spec.rb builds them.
  #
  #   0 conv | 1-2 tool | 3-4 conv | 5-6 tool | 7 conv | 8-10 tail
  def mixed_history(store: Lain::Store.new)
    blocks = [[text("ask")], [tool_use(0)], [tool_result(0)],
              [text("so")], [text("then")], [tool_use(1)], [tool_result(1)],
              [text("ok")], [text("more")], [text("and")], [text("last")]]
    blocks.each_with_index.inject(Lain::Timeline.empty(store:)) do |timeline, (content, index)|
      timeline.commit(role: index.even? ? "user" : "assistant", content:)
    end
  end

  def tool?(message) = message.fetch("content").any? { |block| block.fetch("type").start_with?("tool_") }

  def indices_of(messages, span) = span.select { |index| yield(messages.fetch(index)) }

  # {Lain::Compaction::Strategy::Elide}, cut to the tool stretches: it inherits
  # the real attestation and answers only the contiguous runs of tool-carrying
  # messages.
  def elide_on_tools
    Class.new(Lain::Compaction::Strategy::Elide) do
      def name = "ElideOnTools"

      def propose_ranges(messages, span:)
        conversational = ComposedFixtures.indices_of(messages, span) { |message| !ComposedFixtures.tool?(message) }
        Lain::IntervalPartition.covering(span, excluding: conversational, owner: name).validated
      end
    end.new
  end

  # The deterministic stand-in for a model-backed span summarizer: the
  # conversational runs, and only those long enough to be worth one call, so a
  # lone conversational turn between two tool rounds is left for the derivation
  # to retain in place.
  def summarize_conversation
    Class.new(Lain::Compaction::Strategy::Base) do
      def name = "SummarizeConversation"

      def propose_ranges(messages, span:)
        tools = ComposedFixtures.indices_of(messages, span) { |message| ComposedFixtures.tool?(message) }
        Lain::IntervalPartition.covering(span, excluding: tools, owner: name).validated
                               .select { |run| run.size > 1 }
      end

      def blocks(messages) = [{ "type" => "text", "text" => "[#{messages.size} messages summarized]" }]
    end.new.freeze
  end

  def texts(turn) = turn.content.map { |block| block["text"] }
end

RSpec.describe Lain::Compaction::Strategy::Composed do
  let(:fixtures) { ComposedFixtures }
  let(:messages) { ComposedFixtures.span(8) }
  let(:left) { ComposedFixtures.marking("Left", [0..1, 2..3]) }
  let(:right) { ComposedFixtures.marking("Right", [5..6]) }

  describe "the ranges two composed strategies propose" do
    it "answers both operands' ranges, in ascending order, when they are disjoint" do
      expect((left | right).ranges(messages, span: 0..7)).to eq([0..1, 2..3, 5..6])
    end

    it "answers them in one order whichever way round the operands are" do
      expect((right | left).ranges(messages, span: 0..7)).to eq([0..1, 2..3, 5..6])
    end

    # Stateless dispatch: the range that comes back from #validated IS the
    # object the fold hands to the collapse, so the tag rides along with no
    # memo and no slice-content matching.
    it "tags every range with the operand that proposed it" do
      owners = (left | right).ranges(messages, span: 0..7).map(&:owner)

      expect(owners).to eq([left, left, right])
    end

    it "keeps the innermost proposer's tag through a nested composition" do
      third = ComposedFixtures.marking("Third", [7..7])
      owners = ((left | right) | third).ranges(messages, span: 0..7).map(&:owner)

      expect(owners).to eq([left, left, right, third])
    end

    it "answers ranges a plain Range slices messages exactly as" do
      range = (left | right).ranges(messages, span: 0..7).first

      expect(range).to be_a(Range)
      expect(messages[range]).to eq(messages[0..1])
      expect(range).to be_frozen
    end
  end

  describe "the partiality that is the contract" do
    it "refuses an overlap, naming both operands and the overlapping indices" do
      clashing = ComposedFixtures.marking("Right", [3..4])

      expect { (left | clashing).ranges(messages, span: 0..7) }
        .to raise_error(described_class::Overlap, /Left and Right.*3\.\.3/)
    end

    # The identical operands are the example: a strategy claims its own ranges,
    # so composing one with itself is the smallest overlap there is, and the
    # generator that draws populations for the monoid laws is built to make it
    # undrawable.
    it "refuses a strategy composed with itself, which always overlaps" do
      expect { (left | left).ranges(messages, span: 0..7) } # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands
        .to raise_error(described_class::Overlap)
    end

    it "is refused as the interval partition it fails to be, so every rescue site still catches it" do
      clashing = ComposedFixtures.marking("Right", [3..4])

      expect { (left | clashing).ranges(messages, span: 0..7) }
        .to raise_error(Lain::Compaction::Strategy::NotAPartition)
    end

    it "refuses collapsing a slice no operand proposed, rather than dying on nil" do
      expect { (left | right).collapse(messages) }
        .to raise_error(described_class::Untagged, /Left \| Right/)
    end
  end

  describe "the collapse a composed strategy answers" do
    it "collapses each range through the strategy that proposed it" do
      composed = left | right
      collapsed = composed.ranges(messages, span: 0..7)
                          .map { |range| composed.collapse(messages[range], range:).content }

      expect(collapsed).to eq([[fixtures.text("<Left 2>")], [fixtures.text("<Left 2>")],
                               [fixtures.text("<Right 2>")]])
    end

    # The operand that answered, NOT the pair: "strategy Left | Mute answered
    # nil" is findable and literally false about Left, which answered fine.
    it "names the operand that answered, when one of them answers something that is not blocks" do
      mute = Class.new(Lain::Compaction::Strategy::Base) do
        def name = "Mute"
        def propose_ranges(_messages, **) = [6..7]
        def blocks(_messages) = nil
      end.new.freeze
      composed = left | mute
      range = composed.ranges(messages, span: 0..7).last

      expect { composed.collapse(messages[range], range:) }
        .to raise_error(Lain::Compaction::Strategy::NotBlocks, /strategy Mute answered nil/)
    end

    it "routes by the tag's OWNER, refusing a range some other composition tagged" do
      stranger = ComposedFixtures.marking("Stranger", [0..1])
      foreign = (stranger | right).ranges(messages, span: 0..7).first

      expect { (left | right).collapse(messages[foreign], range: foreign) }
        .to raise_error(described_class::Untagged, /Left \| Right/)
    end
  end

  describe "the Identity strategy as the unit" do
    it "proposes exactly the operand's own ranges, from either side" do
      identity = Lain::Compaction::Strategy::Identity.new

      expect((left | identity).ranges(messages, span: 0..7)).to eq(left.ranges(messages, span: 0..7))
      expect((identity | left).ranges(messages, span: 0..7)).to eq(left.ranges(messages, span: 0..7))
    end

    it "collapses exactly as the operand alone does" do
      composed = left | Lain::Compaction::Strategy::Identity.new
      range = composed.ranges(messages, span: 0..7).first

      expect(composed.collapse(messages[range], range:)).to eq(left.collapse(messages[range]))
    end
  end

  describe "the shape of the object" do
    # The un-deferral ruling and the operator both belong in `lib/`; this pins
    # that the registry can be read for them.
    it "is declared a commutative monoid on #| with the Identity strategy as its unit" do
      declared = Lain::Algebra.registry.declarations
                              .select { |entry| entry.subject == Lain::Compaction::Strategy::Base }

      expect(declared.map(&:structure)).to contain_exactly(:monoid, :commutative_monoid)
      expect(declared.map(&:operation).uniq).to eq([:|])
      expect(declared.first.identity).to be_a(Lain::Compaction::Strategy::Identity)
    end

    it "is one more subclass of the seam, with both questions still owned by Base" do
      %i[ranges collapse].each do |question|
        expect(described_class.instance_method(question).owner).to be(Lain::Compaction::Strategy::Base)
      end
    end

    it "is a frozen strategy naming both operands" do
      composed = left | right

      expect(composed).to be_frozen
      expect(composed.name).to eq("Left | Right")
      expect(composed.name).to be_frozen
    end

    it "sums both operands' address hit and miss counts, so a Source can journal the rate" do
      composed = left | right

      expect([composed.hits, composed.misses]).to eq([0, 0])
    end

    it "answers every leaf under it, and never itself" do
      third = ComposedFixtures.marking("Third", [7..7])

      expect(((left | right) | third).operands).to eq([left, right, third])
      expect(left.operands).to eq([left])
    end

    # Stated mechanically, per CLAUDE.md: {Scheduler::COMPOSE} makes the
    # pipeline shareable, a Range SUBCLASS is not frozen the way a literal is,
    # and dropping `freeze` from Owned leaves the whole law sweep green.
    it "is shareable, as is every range it tags and any partition holding one" do
      composed = left | right
      ranges = composed.ranges(messages, span: 0..7)

      expect(composed).to be_deeply_frozen
      expect(ranges.map { |range| Ractor.shareable?(range) }).to eq([true, true, true])
      expect(Lain::IntervalPartition.of(0..7, ranges, owner: composed.name)).to be_deeply_frozen
    end
  end

  # The case `chunk-derived-context-timeline.md` follow-up 3 names: elide on
  # tool spans, summarize on conversational ones, ONE derivation.
  describe "the motivating case, end to end" do
    let(:source) { ComposedFixtures.mixed_history }
    let(:strategy) { ComposedFixtures.elide_on_tools | ComposedFixtures.summarize_conversation }
    let(:derived) { Lain::Compaction::Derivation.new(strategy:, keep_last: 3).derive(source) }

    it "elides the tool stretches, summarizes the conversational one, and retains the gaps in place" do
      expect(derived.to_a.map { |turn| fixtures.texts(turn) })
        .to match([["ask"],
                   [a_string_including(Lain::Compaction::Strategy::Elide::ELIDED),
                    a_string_including(Lain::Compaction::Strategy::Elide::ELIDED)],
                   ["[2 messages summarized]"],
                   [a_string_including(Lain::Compaction::Strategy::Elide::ELIDED),
                    a_string_including(Lain::Compaction::Strategy::Elide::ELIDED)],
                   ["ok"], ["more"], ["and"], ["last"]])
    end

    it "retains the turns in the gaps verbatim, in position" do
      expect(derived.to_a.values_at(0, 4).map(&:content))
        .to eq(source.to_a.values_at(0, 7).map(&:content))
    end

    it "names each replacement's preimage, so the fibre of a composed collapse is still exact" do
      digests = source.to_a.map(&:digest)

      # `match_array` per spec/lain/compaction/derivation_spec.rb: an event's
      # causal parents are a SET on the wire, and the commit normalizes them.
      expect(derived.to_a.map(&:causal_parents))
        .to match([[], match_array(digests[1..2]), match_array(digests[3..4]),
                   match_array(digests[5..6]), [], [], [], []])
    end

    it "answers the same chain whichever way round the two strategies compose" do
      other = ComposedFixtures.summarize_conversation | ComposedFixtures.elide_on_tools

      expect(Lain::Compaction::Derivation.new(strategy: other, keep_last: 3).derive(source).head_digest)
        .to eq(derived.head_digest)
    end

    # THE PRODUCTION PATH, and the one the end-to-end example above misses:
    # `Source::Derived#over` wraps EVERY operator-supplied strategy in PinCuts
    # (`source/derived.rb:103`) before handing it to a Derivation (`:138`), and
    # PinCuts delegates the collapse. A composition whose ranges were perfect
    # died there of NotImplementedError. Reached through `const_get` -- the
    # precedent spec/lain/interval_partition_spec.rb already sets for this same
    # private wrapper -- rather than by rebuilding a whole Source, which needs a
    # need, a cold, a clock, a journal and a session to say one thing.
    it "collapses through the PinCuts wrapper every operator-supplied strategy is given" do
      wrapped = Lain::Compaction::Source::Derived.const_get(:PinCuts)
                                                 .new(inner: strategy, pins: Lain::Context::PinnedMessages::NONE)

      expect(Lain::Compaction::Derivation.new(strategy: wrapped, keep_last: 3).derive(source).head_digest)
        .to eq(derived.head_digest)
    end

    it "journals the edge under a name that says which two policies ran" do
      journal = []
      Lain::Compaction::Derivation.new(strategy:, keep_last: 3, journal:).derive(source)

      expect(journal.first.strategy).to eq("ElideOnTools | SummarizeConversation")
    end
  end
end
