# frozen_string_literal: true

# Spans built by a module rather than by `let`s, because the law group below is
# included in a GROUP BODY: `include_examples` runs there, and a config Hash
# written there closes over `self` = the example group, where no `let` exists
# yet. spec/support/algebra_generators.rb documents the same rule and answers it
# the same way.
module ElideFixtures
  module_function

  def message(body, role: "user") = { "role" => role, "content" => [{ "type" => "text", "text" => body }] }

  # Alternating, so a span reads as a real conversation slice.
  def span(size) = Array.new(size) { |i| message(("a".."z").to_a.sample, role: i.even? ? "user" : "assistant") }

  # Sizes are fixed and contents are random: the laws quantify over the spans,
  # and a random SIZE could draw five empty spans and certify nothing. The empty
  # span is IN the draw, since the unit law is read over it.
  def spans = [0, 1, 2, 3, 5].map { |size| span(size) }
end

RSpec.describe Lain::Compaction::Strategy::Elide do
  subject(:elide) { described_class.new }

  let(:span) do
    [ElideFixtures.message("one"), ElideFixtures.message("two", role: "assistant"),
     ElideFixtures.message("three")]
  end

  def texts(replacement) = replacement.content.map { |block| block["text"] }

  def bytes(replacement) = Lain::Canonical.dump(replacement.content)

  describe "what a collapsed span leaves behind" do
    # The invariant summary_snapshot.rb:33-41 states: nothing disappears
    # unattested. A reader can always tell what was there and fetch the original
    # from the Store by address.
    it "attests every message by role, content address and byte count" do
      lines = texts(elide.collapse(span))

      expect(lines.size).to eq(span.size)
      span.zip(lines) do |message, line|
        expect(line).to include(message["role"], Lain::Canonical.digest(message),
                                "#{Lain::Canonical.dump(message).bytesize} bytes")
      end
    end

    it "says the bytes are gone rather than implying a summary was taken" do
      expect(texts(elide.collapse(span))).to all(include(described_class::ELIDED))
    end

    it "attests a message carrying no content blocks rather than omitting it" do
      blockless = { "role" => "user", "content" => [] }

      expect(texts(elide.collapse([blockless]))).to contain_exactly(include(Lain::Canonical.digest(blockless)))
    end

    # The role is ours -- every writer in `lib/` commits one -- so a missing one
    # is a caller bug and not a blank to render past. This is byte-for-byte the
    # posture SummarySnapshot#attest takes via `fetch`
    # (spec/lain/compaction/summary_snapshot_spec.rb:464-467).
    it "raises on a message with no role at all" do
      expect { elide.collapse([{ "content" => [] }]) }.to raise_error(KeyError, /role/)
    end
  end

  describe "what makes it the control arm" do
    it "answers byte-identical content for one span, collapsed twice" do
      expect(bytes(described_class.new.collapse(span))).to eq(bytes(described_class.new.collapse(span)))
    end

    # The homomorphism read as the property it buys: cut the span in two at
    # EVERY position, collapse each half, concatenate. A strategy whose output
    # moved with the boundary could not be the control arm any comparison of
    # compaction policies is measured against.
    it "answers the same bytes wherever the boundary between two ranges falls" do
      cuttings = (0..span.size).map { |at| elide.collapse(span.take(at)) + elide.collapse(span.drop(at)) }

      expect(cuttings.map { |cut| bytes(cut) }.uniq).to eq([bytes(elide.collapse(span))])
    end

    it "consults no model, oracle or journal, holding no collaborator to consult" do
      expect(described_class.instance_method(:initialize).arity).to eq(0)
      expect(elide.instance_variables).to be_empty
      expect(texts(elide.collapse(span))).not_to be_empty
    end

    it "is a deeply frozen, shareable value" do
      expect(elide).to be_frozen
      expect(Ractor.shareable?(elide)).to be(true)
    end
  end

  describe "the empty span" do
    # SummarySnapshot::NOTHING exists because that duck answers a STRING, where
    # an empty one becomes a text block Anthropic rejects. This strategy maps
    # into the free monoid instead, which HAS a unit: an empty span collapses to
    # DROP, so the range vanishes with no replacement event at all rather than
    # rendering a placeholder line about nothing. That is also the unit law the
    # homomorphism group reads below, so answering a NOTHING line here would
    # break the property this strategy exists for.
    it "answers the unit, so no blank block is ever built" do
      expect(elide.collapse([])).to be(Lain::Compaction::Strategy::DROP)
      expect(elide.blocks([])).to be_empty
    end

    it "leaves a span it is folded into exactly as it found it" do
      collapsed = elide.collapse(span)

      expect(elide.collapse([]) + collapsed).to be(collapsed)
    end
  end

  describe "the ranges it proposes" do
    it "offers the whole span in one range, which #ranges validates unchanged" do
      expect(elide.ranges(span, span: 0..2)).to eq([0..2])
    end
  end

  describe "the algebra it declares" do
    it "is elementwise by construction and pure on the operation it declares" do
      expect(elide).to be_a(Lain::Algebra::Elementwise)
      expect(elide.pure?(:blocks)).to be(true)
    end

    it "declares both structures on #blocks, never on the sealed #collapse" do
      declared = Lain::Algebra.registry.declarations.select { |entry| entry.subject == described_class }

      expect(declared.map { |entry| [entry.operation, entry.structure] })
        .to contain_exactly(%i[blocks elementwise], %i[blocks pure])
    end
  end

  # The plain law `collapse(A ++ B) == collapse(A) ++ collapse(B)`, which holds
  # for an unconditional (Alone) strategy and is exactly what makes this one the
  # honest floor under a model-backed strategy. The registry sweep judges the
  # elementwise and purity declarations; this group judges the homomorphism
  # itself, which no structure in the registry names.
  describe "held to the homomorphism law over generated spans" do
    strategy = Lain::Compaction::Strategy::Elide.new
    drawn = ElideFixtures.spans

    include_examples "a monoid homomorphism",
                     collapse: ->(messages) { strategy.collapse(messages) },
                     unit: Lain::Compaction::Strategy::DROP,
                     spans: -> { drawn }
  end
end
