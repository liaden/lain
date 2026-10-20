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
end
