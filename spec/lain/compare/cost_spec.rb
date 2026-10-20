# frozen_string_literal: true

RSpec.describe Lain::Compare::Cost do
  def self.cost_generator
    gens = PropCheck::Generators
    gens.one_of(
      gens.constant(described_class::NONE),
      gens.integer.map { |n| described_class::Priced.new(amount: BigDecimal(n.abs) / 8) },
      gens.alphanumeric_string.map { |s| described_class::Unpriced.new(reason: "no price for #{s}") }
    )
  end

  describe "the monoid laws, with none as the unit" do
    include_examples "a monoid",
                     operation: ->(a, b) { a + b },
                     identity: described_class::NONE,
                     generator: cost_generator
  end

  describe "#+" do
    let(:priced) { described_class::Priced.new(amount: BigDecimal("0.5")) }
    let(:unpriced) { described_class::Unpriced.new(reason: "no price") }

    it "adds priced amounts" do
      sum = priced + described_class::Priced.new(amount: BigDecimal("0.25"))
      expect(sum).to eq(described_class::Priced.new(amount: BigDecimal("0.75")))
    end

    it "lets unpriced absorb in either order" do
      expect([priced + unpriced, unpriced + priced]).to all(eq(unpriced))
    end

    it "keeps none distinct from a measured zero" do
      expect(described_class::NONE).not_to eq(described_class::Priced.new(amount: BigDecimal(0)))
    end
  end

  describe ".sum" do
    it "answers none for no costs" do
      expect(described_class.sum([])).to be(described_class::NONE)
    end

    it "pools priced costs" do
      costs = [BigDecimal("0.1"), BigDecimal("0.2")].map { |a| described_class::Priced.new(amount: a) }
      expect(described_class.sum(costs)).to eq(described_class::Priced.new(amount: BigDecimal("0.3")))
    end
  end

  describe "Unpriced" do
    it "raises the refusal when its amount is read" do
      expect { described_class::Unpriced.new(reason: "no price").amount }.to raise_error(Lain::PriceBook::UnknownModel)
    end

    it "describes the refusals in the one wording" do
      unpriced = [described_class::Unpriced.new(reason: "a"), described_class::Unpriced.new(reason: "b")]
      expect(described_class::Unpriced.describe(unpriced)).to eq("not priced — a; b")
    end
  end

  it "keeps every constructor Ractor-shareable" do
    values = [described_class::NONE, described_class::Priced.new(amount: BigDecimal(1)),
              described_class::Unpriced.new(reason: "x")]
    expect(values).to all(be_deeply_frozen)
  end
end
