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

  it "has structural equality" do
    twin = described_class.new(capability: :thinking, requirer: "Prune", provider: "Provider::Mock")
    expect(event).to eq(twin)
    expect(event.hash).to eq(twin.hash)
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

  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(capability: :thinking,
                                   requirer: "Lain::Context",
                                   provider: "Lain::Provider::Mock")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"capability_degraded","capability":"thinking","requirer":"Lain::Context",' \
        '"provider":"Lain::Provider::Mock"}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        capability: :thinking,
        requirer: "Lain::Context",
        provider: "Lain::Provider::Mock"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing capability, naming it" do
      given = {
        capability: :thinking,
        requirer: "Lain::Context",
        provider: "Lain::Provider::Mock"
      }
      expect { described_class.new(**given.except(:capability)) }.to raise_error(ArgumentError, /capability/)
    end
  end
end
