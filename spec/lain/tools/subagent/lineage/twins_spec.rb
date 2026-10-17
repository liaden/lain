# frozen_string_literal: true

RSpec.describe Lain::Tools::Subagent::Lineage::Twins do
  it "counts each key from 1 on its own" do
    twins = described_class.new

    expect([twins.next("a"), twins.next("a"), twins.next("b")]).to eq([1, 2, 1])
  end

  it "is the same registry when scoped, so every writer given it shares one count" do
    twins = described_class.new

    expect(twins.scoped).to equal(twins)
  end

  describe "::Null" do
    it "scopes to a registry of its own each time, so a detached writer counts alone" do
      first = described_class::Null.scoped
      first.next("a")

      expect(described_class::Null.scoped.next("a")).to eq(1)
    end
  end
end
