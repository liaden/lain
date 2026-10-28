# frozen_string_literal: true

require "json"

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

  it "journals byte for byte" do
    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"price_tier_crossed","model":"claude-haiku-5-5","prompt_tokens":104000,"boundary":100000,' \
      '"standard_cost":"0.0104","tier_cost":"0.052","decision":"approve"}'
    )
  end

  it "shares the model String across equal records" do
    build = lambda do
      described_class.new(model: +"claude-haiku-5-5", prompt_tokens: 1, boundary: 1, standard_cost: 1, tier_cost: 2,
                          decision: :allow)
    end

    expect(build.call.model).to equal(build.call.model)
  end

  %i[approve deny allow refuse carried].each do |decision|
    it "accepts the #{decision} decision" do
      built = described_class.new(model: "m", prompt_tokens: 1, boundary: 1, standard_cost: 1, tier_cost: 2, decision:)

      expect(built.decision).to eq(decision)
    end
  end

  it "refuses a decision outside the set, naming decision" do
    expect do
      described_class.new(model: "m", prompt_tokens: 1, boundary: 1, standard_cost: 1, tier_cost: 2, decision: :maybe)
    end.to raise_error(ArgumentError, /decision must be approve.*got maybe/)
  end

  it "refuses an unknown keyword" do
    expect do
      described_class.new(model: "m", prompt_tokens: 1, boundary: 1, standard_cost: 1, tier_cost: 2, decision: :allow,
                          extra: 1)
    end.to raise_error(ArgumentError, /extra/)
  end

  it "reads a String decision as the Symbol a reader compares against" do
    expect(record.decision).to eq(:approve)
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
