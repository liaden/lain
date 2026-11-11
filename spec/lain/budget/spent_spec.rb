# frozen_string_literal: true

RSpec.describe Lain::Budget::Spent do
  def self.spent_generator
    usage = PropCheck::Generators.fixed_hash(
      input_tokens: PropCheck::Generators.nonnegative_integer,
      output_tokens: PropCheck::Generators.nonnegative_integer,
      cache_creation_input_tokens: PropCheck::Generators.nonnegative_integer,
      cache_read_input_tokens: PropCheck::Generators.nonnegative_integer
    ).map { |fields| Lain::Usage.new(**fields) }
    dollars = PropCheck::Generators.tuple(PropCheck::Generators.nonnegative_integer, PropCheck::Generators.boolean)
                                   .map do |cents, complete|
      Lain::Friction::CacheWaste::Dollars.new(amount: BigDecimal(cents) / 100, complete:)
    end
    PropCheck::Generators.tuple(usage, dollars).map { |u, d| described_class.new(usage: u, dollars: d) }
  end

  it "has a zero of zero usage and zero dollars" do
    expect(described_class.zero).to eq(
      described_class.new(usage: Lain::Usage.zero, dollars: Lain::Friction::CacheWaste::Dollars.zero)
    )
  end

  it "adds fieldwise" do
    one = described_class.new(usage: Lain::Usage.new(input_tokens: 2),
                              dollars: Lain::Friction::CacheWaste::Dollars.of(BigDecimal("0.5")))
    sum = one + one

    expect([sum.usage.input_tokens, sum.dollars.amount]).to eq([4, BigDecimal(1)])
  end

  describe ".of" do
    let(:clock) { -> { Time.utc(2026, 11, 11, 14) } }

    it "carries a response's usage and its price" do
      response = Lain::Response.new(content: [], stop_reason: :end_turn, model: "claude-opus-5-5",
                                    usage: Lain::Usage.new(input_tokens: 10_000))

      spent = described_class.of(response, prices: Lain::PriceBook.default, clock:)

      expect([spent.usage, spent.dollars]).to eq([Lain::Usage.new(input_tokens: 10_000),
                                                  Lain::Friction::CacheWaste::Dollars.of(BigDecimal("0.04"))])
    end

    it "prices a model and a usage read back from a record, with no response to hand" do
      spent = described_class.paid("claude-opus-5-5", Lain::Usage.new(input_tokens: 10_000),
                                   prices: Lain::PriceBook.default, clock:)

      expect(spent.dollars).to eq(Lain::Friction::CacheWaste::Dollars.of(BigDecimal("0.04")))
    end

    it "marks the dollars unknown for a model the book has no row for, keeping the usage" do
      response = Lain::Response.new(content: [], stop_reason: :end_turn, model: "qwen3:4b",
                                    usage: Lain::Usage.new(input_tokens: 10_000))

      spent = described_class.of(response, prices: Lain::PriceBook.default, clock:)

      expect([spent.usage.input_tokens, spent.dollars]).to eq([10_000, Lain::Friction::CacheWaste::Dollars.unknown])
    end
  end

  describe "the commutative monoid laws" do
    include_examples "a monoid",
                     operation: ->(a, b) { a + b },
                     identity: described_class.zero,
                     generator: spent_generator

    include_examples "a commutative monoid",
                     operation: ->(a, b) { a + b },
                     generator: spent_generator
  end
end
