# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Masked do
  it "carries the text, the fresh count and the prior count" do
    expect(described_class.new(text: "a", fresh: 1, prior: 2)).to have_attributes(text: "a", fresh: 1, prior: 2)
  end

  it "is a frozen value object, shareable even from a mutable text" do
    expect(described_class.new(text: +"a", fresh: 0, prior: 0)).to be_deeply_frozen
  end

  it "joins by concatenating the text and adding both counts" do
    joined = described_class.new(text: "a", fresh: 1, prior: 0) + described_class.new(text: "b", fresh: 2, prior: 3)

    expect(joined).to eq(described_class.new(text: "ab", fresh: 3, prior: 3))
  end

  describe "the monoid laws" do
    def self.masked_generator
      PropCheck::Generators.tuple(
        PropCheck::Generators.one_of(
          PropCheck::Generators.printable_ascii_string,
          PropCheck::Generators.one_of(*["é", "日本", "😀", "e\u0301"].map { |t| PropCheck::Generators.constant(t) })
        ),
        PropCheck::Generators.nonnegative_integer,
        PropCheck::Generators.nonnegative_integer
      ).map { |text, fresh, prior| described_class.new(text:, fresh:, prior:) }
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a + b },
                     identity: described_class.plain(""),
                     generator: masked_generator
  end
end
