# frozen_string_literal: true

RSpec.describe Lain::Telemetry::PriceTierCrossed do
  subject(:record) do
    described_class.new(model: "claude-haiku-5-5", prompt_tokens: 104_000, boundary: 100_000,
                        standard_cost: BigDecimal("0.0104"), tier_cost: BigDecimal("0.052"), decision: "approve")
  end

  it "journals the crossing's figures, its costs as fixed-point strings" do
    expect(record.to_journal).to eq("type" => "price_tier_crossed", "model" => "claude-haiku-5-5",
                                    "prompt_tokens" => 104_000, "boundary" => 100_000,
                                    "standard_cost" => "0.0104", "tier_cost" => "0.052", "decision" => :approve)
  end

  it "reads a String decision as the Symbol a reader compares against" do
    expect(record.decision).to eq(:approve)
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
