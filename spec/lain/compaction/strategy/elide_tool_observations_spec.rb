# frozen_string_literal: true

# Built by a module rather than by `let`s, for the reason
# spec/lain/compaction/strategy/elide_spec.rb records: the law-shaped groups
# below run in a GROUP BODY, where no `let` exists yet.
module ElideToolObservationsFixtures
  module_function

  def text(body) = { "type" => "text", "text" => body }

  def message(*blocks, role: "user") = { "role" => role, "content" => blocks }

  def tool_use(id) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => {} }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "ok" }

  # The shape ComposedFixtures#mixed_history builds, kept identical on purpose:
  # this strategy is the promotion of that file's anonymous `elide_on_tools`
  # prototype, so it is held to the same history.
  #
  #   0 conv | 1-2 tool | 3-4 conv | 5-6 tool | 7 conv | 8-10 tail
  def mixed_blocks
    [[text("ask")], [tool_use(0)], [tool_result(0)],
     [text("so")], [text("then")], [tool_use(1)], [tool_result(1)],
     [text("ok")], [text("more")], [text("and")], [text("last")]]
  end

  def conversational_blocks = %w[ask so then ok more and last].map { |body| [text(body)] }

  # Roles alternate by index, so a `tool_use` is always the assistant's and its
  # answer always the user's -- what spec/lain/compaction/derivation_spec.rb
  # builds and what {Context::Conversation} accepts.
  def history(blocks, store: Lain::Store.new)
    blocks.each_with_index.inject(Lain::Timeline.empty(store:)) do |timeline, (content, index)|
      timeline.commit(role: index.even? ? "user" : "assistant", content:)
    end
  end

  def messages(blocks)
    blocks.each_with_index.map { |content, index| message(*content, role: index.even? ? "user" : "assistant") }
  end

  def random_span(size)
    Array.new(size) { rand < 0.5 ? message(tool_use(0), tool_result(0), role: "assistant") : message(text("hi")) }
  end

  def texts(turn) = turn.content.map { |block| block["text"] }
end

RSpec.describe Lain::Compaction::Strategy::ElideToolObservations do
  subject(:strategy) { described_class.new }

  let(:fixtures) { ElideToolObservationsFixtures }
  let(:mixed) { ElideToolObservationsFixtures.messages(ElideToolObservationsFixtures.mixed_blocks) }

  def bytes(replacement) = Lain::Canonical.dump(replacement.content)

  describe "the ranges it claims" do
    it "covers exactly the messages carrying tool blocks" do
      claimed = strategy.ranges(mixed, span: 0...8).flat_map(&:to_a)

      expect(claimed).to eq([1, 2, 5, 6])
    end

    it "claims two adjacent tool messages as one range, not two" do
      expect(strategy.ranges(mixed, span: 0...8)).to eq([1..2, 5..6])
    end

    it "claims a tool message carrying text alongside its tool block" do
      mixed_message = [fixtures.message(fixtures.text("let me check"), fixtures.tool_use(0), role: "assistant")]

      expect(strategy.ranges(mixed_message, span: 0...1)).to eq([0..0])
    end

    it "claims nothing outside the span it was offered" do
      expect(strategy.ranges(mixed, span: 3...8)).to eq([5..6])
    end
  end

  # The whole reason {Compaction::ToolMessages} exists: if this strategy spelled
  # the predicate itself, its selection could drift from the conversational one
  # and {Strategy::Composed} would raise Overlap at proposal time, mid-turn, in
  # a live chat. Behavioural agreement is the guard -- a respelling that agrees
  # is harmless, and one that does not is exactly what this catches.
  describe "the predicate it does not spell" do
    it "answers what ToolMessages.tool_runs answers, over many random spans" do
      200.times do
        messages = fixtures.random_span(rand(0..12))
        span = 0...messages.size

        expect(strategy.propose_ranges(messages, span:))
          .to eq(Lain::Compaction::ToolMessages.tool_runs(messages, span:, owner: strategy.name))
      end
    end

    it "never claims an index the conversational selection also claims" do
      200.times do
        messages = fixtures.random_span(rand(0..12))
        span = 0...messages.size

        conversational = Lain::Compaction::ToolMessages.conversational_runs(messages, span:, owner: "spec")

        expect(strategy.ranges(messages, span:).flat_map(&:to_a) & conversational.flat_map(&:to_a)).to be_empty
      end
    end
  end

  describe "a derivation over a mixed span" do
    let(:source) { fixtures.history(fixtures.mixed_blocks) }
    let(:derived) { Lain::Compaction::Derivation.new(strategy:, keep_last: 3).derive(source) }

    it "elides the tool stretches and leaves the conversational turns in place" do
      expect(derived.to_a.map { |turn| fixtures.texts(turn) })
        .to match([["ask"],
                   [a_string_including(Lain::Compaction::Strategy::Elide::ELIDED),
                    a_string_including(Lain::Compaction::Strategy::Elide::ELIDED)],
                   ["so"], ["then"],
                   [a_string_including(Lain::Compaction::Strategy::Elide::ELIDED),
                    a_string_including(Lain::Compaction::Strategy::Elide::ELIDED)],
                   ["ok"], ["more"], ["and"], ["last"]])
    end

    it "retains every conversational turn verbatim, in its original order" do
      expect(derived.to_a.values_at(0, 2, 3, 5, 6, 7, 8).map(&:content))
        .to eq(source.to_a.values_at(0, 3, 4, 7, 8, 9, 10).map(&:content))
    end

    it "names each replacement's preimage, so the fibre of the collapse stays exact" do
      digests = source.to_a.map(&:digest)

      expect(derived.to_a.map(&:causal_parents))
        .to match([[], match_array(digests[1..2]), [], [], match_array(digests[5..6]), [], [], [], []])
    end
  end

  describe "a purely conversational span" do
    let(:source) { fixtures.history(fixtures.conversational_blocks) }
    let(:derived) { Lain::Compaction::Derivation.new(strategy:, keep_last: 3).derive(source) }

    it "proposes no ranges at all" do
      messages = fixtures.messages(fixtures.conversational_blocks)

      expect(strategy.ranges(messages, span: 0...4)).to be_empty
    end

    it "derives a chain whose content is the source's, turn for turn" do
      expect(derived.to_a.map(&:content)).to eq(source.to_a.map(&:content))
    end

    it "writes no replacement, so no derived turn subsumes anything" do
      expect(derived.to_a.map(&:causal_parents)).to all(be_empty)
    end
  end

  # #blocks is inherited byte-for-byte, so the concatenation its parent is held
  # to is the one this strategy answers; only the selection moves.
  describe "the attestation it inherits" do
    it "leaves #blocks owned by Elide, so the per-message map is the parent's" do
      expect(described_class.instance_method(:blocks).owner).to be(Lain::Compaction::Strategy::Elide)
    end

    it "overrides the selection and nothing else" do
      expect(described_class.instance_methods(false)).to contain_exactly(:propose_ranges)
    end

    it "attests every claimed message by role, content address and byte count" do
      claimed = mixed[1..2]
      lines = strategy.collapse(claimed).content.map { |block| block["text"] }

      claimed.zip(lines) do |message, line|
        expect(line).to include(message["role"], Lain::Canonical.digest(message),
                                "#{Lain::Canonical.dump(message).bytesize} bytes")
      end
    end

    it "consults no model, oracle or journal, holding no collaborator to consult" do
      expect { described_class.new(Lain::Channel::Null.instance) }.to raise_error(ArgumentError)
      expect(strategy.instance_variables).to be_empty
      expect(strategy).to be_deeply_frozen
    end
  end

  # The property that makes Elide the control arm, re-read over a PARTIAL-span
  # claim: the card says to stop if it does not survive the narrower selection.
  # It does, and the reason is structural -- the claim narrows #propose_ranges,
  # while the homomorphism is a statement about #blocks, which is untouched.
  describe "the byte-identity property, held over the ranges it actually claims" do
    it "answers the same bytes wherever a claimed run is cut in two" do
      strategy.ranges(mixed, span: 0...8).each do |range|
        claimed = mixed[range]
        cuttings = (0..claimed.size).map do |at|
          halves = [claimed.take(at), claimed.drop(at)]
          Lain::Canonical.dump(halves.flat_map { |half| strategy.collapse(half).content })
        end

        expect(cuttings.uniq).to eq([bytes(strategy.collapse(claimed))])
      end
    end

    it "answers byte-identical content for one claim, collapsed twice" do
      expect(bytes(described_class.new.collapse(mixed[1..2])))
        .to eq(bytes(described_class.new.collapse(mixed[1..2])))
    end

    it "answers the unit for an empty claim, so no blank block is ever built" do
      expect(strategy.collapse([])).to be(Lain::Compaction::Strategy::DROP)
    end
  end

  # Its own instance, over the parent's population shape, drawn fresh per law for
  # the reason spec/support/shared_examples/pure.rb documents.
  describe "held to the purity laws on #blocks" do
    strategy = described_class.new
    plain = ElideToolObservationsFixtures.conversational_blocks
    spans = -> { [[], *(1..3).map { |size| ElideToolObservationsFixtures.messages(plain.first(size)) }] }

    include_examples "a pure operation",
                     instance: -> { strategy },
                     operation: :blocks,
                     population: spans
  end
end
