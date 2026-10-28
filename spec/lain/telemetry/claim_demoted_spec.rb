# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ClaimDemoted do
  it "journals as a claim_demoted record naming the strategy and the count" do
    expect(described_class.new(strategy: "summarizing", count: 2).to_journal)
      .to eq("type" => "claim_demoted", "strategy" => "summarizing", "count" => 2)
  end

  it "rejects a non-positive count" do
    expect { described_class.new(strategy: "summarizing", count: 0) }.to raise_error(ArgumentError)
  end

  it "rejects a missing strategy" do
    expect { described_class.new(strategy: nil, count: 1) }.to raise_error(ArgumentError)
  end

  it "stays shareable" do
    expect(Ractor.shareable?(described_class.new(strategy: "summarizing", count: 1))).to be(true)
  end

  it "prints its journal line" do
    expect(JSON.generate(described_class.new(strategy: "summary", count: 2).to_journal))
      .to eq('{"type":"claim_demoted","strategy":"summary","count":2}')
  end
end
