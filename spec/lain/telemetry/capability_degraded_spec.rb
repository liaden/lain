# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::CapabilityDegraded do
  subject(:event) do
    described_class.new(capability: :thinking, requirer: "Prune", provider: "Provider::Mock")
  end

  it "carries the capability, requirer, and provider" do
    expect(event.capability).to eq(:thinking)
    expect(event.requirer).to eq("Prune")
    expect(event.provider).to eq("Provider::Mock")
  end

  it "is a frozen value object with structural equality" do
    twin = described_class.new(capability: :thinking, requirer: "Prune", provider: "Provider::Mock")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
    expect(event.hash).to eq(twin.hash)
  end

  it "is Ractor-shareable (no reachable mutable state)" do
    expect(event).to be_deeply_frozen
  end

  it "journals as a capability_degraded record that round-trips through JSON" do
    expect(event.to_journal).to eq(
      "type" => "capability_degraded", "capability" => :thinking,
      "requirer" => "Prune", "provider" => "Provider::Mock"
    )
    expect(JSON.parse(JSON.generate(event.to_journal))).to include(
      "type" => "capability_degraded", "capability" => "thinking"
    )
  end
end
