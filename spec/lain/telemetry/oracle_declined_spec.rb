# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::OracleDeclined do
  subject(:event) { described_class.new(tier: :model, oracle_digest: "digest-abc", reason: "busy") }

  it "is a frozen, Ractor-shareable value with structural equality" do
    twin = described_class.new(tier: :model, oracle_digest: +"digest-abc", reason: +"busy")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
  end

  it "journals itself as oracle_declined" do
    expect(JSON.parse(JSON.generate(event.to_journal)))
      .to eq("type" => "oracle_declined", "tier" => "model", "oracle_digest" => "digest-abc", "reason" => "busy")
  end

  it "refuses a record that names no tier, no oracle, or no reason" do
    expect { described_class.new(tier: nil, oracle_digest: "d", reason: "busy") }
      .to raise_error(ArgumentError, /tier must name the oracle's tier/)
    expect { described_class.new(tier: :model, oracle_digest: nil, reason: "busy") }
      .to raise_error(ArgumentError, /oracle_digest must name the oracle that declined/)
    expect { described_class.new(tier: :model, oracle_digest: "d", reason: nil) }
      .to raise_error(ArgumentError, /reason must say why it declined/)
  end
end
