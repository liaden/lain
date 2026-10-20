# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Spans do
  def spans(*pairs) = described_class.of(pairs.map { |start, length| described_class::Span.new(start:, length:) })

  def pairs_of(value) = value.map { [_1.start, _1.length] }

  # Offsets accumulate, so every draw is ascending and separated without ever
  # passing through the operation under test.
  def self.spans_generator
    gap_and_length = PropCheck::Generators.tuple(PropCheck::Generators.choose(1..20),
                                                 PropCheck::Generators.choose(1..20))
    PropCheck::Generators.array(gap_and_length, max: 6).map do |steps|
      at = 0
      described_class.of(steps.map do |gap, length|
        described_class::Span.new(start: at += gap, length:).tap { at += length }
      end)
    end
  end

  describe "the union laws" do
    include_examples "a monoid",
                     operation: ->(a, b) { described_class.union(a, b) },
                     identity: described_class::EMPTY,
                     generator: spans_generator

    include_examples "a commutative monoid",
                     operation: ->(a, b) { described_class.union(a, b) },
                     generator: spans_generator

    it "is idempotent", aggregate_failures: false do
      forall(value: coerce(self.class.spans_generator)) do |value:|
        expect(described_class.union(value, value)).to eq(value)
      end
    end
  end

  describe "the semilattice laws, covers as the order" do
    include_examples "a meet semilattice under ancestry",
                     population: lambda {
                       [described_class::EMPTY, spans([0, 3]), spans([5, 3]), spans([2, 10]),
                        spans([0, 2], [4, 2], [9, 1])]
                     },
                     meet: ->(a, b) { described_class.union(a, b) },
                     ancestor_of: ->(whole, part) { whole.covers?(part) }
  end

  describe ".of" do
    it "sorts" do
      expect(pairs_of(spans([5, 1], [0, 2]))).to eq([[0, 2], [5, 1]])
    end

    it "merges an overlap" do
      expect(pairs_of(spans([0, 5], [3, 5]))).to eq([[0, 8]])
    end

    it "merges a touch, because no byte stands between the two" do
      expect(pairs_of(spans([0, 5], [5, 2]))).to eq([[0, 7]])
    end

    it "keeps a span inside another from shortening it" do
      expect(pairs_of(spans([0, 10], [2, 3]))).to eq([[0, 10]])
    end

    it "refuses a negative start by name" do
      expect { spans([-1, 3]) }.to raise_error(Lain::Sensitivity::Spans::NegativeSpan, /start -1/)
    end

    it "refuses a negative length by name" do
      expect { spans([2, -3]) }.to raise_error(Lain::Sensitivity::Spans::NegativeSpan, /length -3/)
    end

    it "is deeply frozen" do
      expect(spans([0, 1])).to be_deeply_frozen
    end
  end

  describe ".union" do
    it "loses no bytes when the later span is merged first" do
      later = spans([5, 3])
      earlier = spans([2, 10])

      expect(pairs_of(described_class.union(later, earlier))).to eq([[2, 10]])
      expect(pairs_of(described_class.union(earlier, later))).to eq([[2, 10]])
    end
  end

  describe ".ascending" do
    it "refuses a span that begins before the previous one ends, naming it" do
      list = [described_class::Span.new(start: 10, length: 2), described_class::Span.new(start: 2, length: 3)]

      expect { described_class.ascending(list) }
        .to raise_error(Lain::Sensitivity::Spans::OutOfOrder, /start 2/)
    end

    it "accepts what detect produces" do
      list = [described_class::Span.new(start: 2, length: 3), described_class::Span.new(start: 10, length: 2)]

      expect(pairs_of(described_class.ascending(list))).to eq([[2, 3], [10, 2]])
    end
  end

  describe "#covers?" do
    it "holds for a part inside one span and fails for one that straddles a gap" do
      whole = spans([0, 4], [6, 4])

      expect(whole.covers?(spans([1, 2]))).to be(true)
      expect(whole.covers?(spans([3, 4]))).to be(false)
    end
  end
end
