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
