# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::MemoryLoaded do
  it "prints its journal line, items key-sorted" do
    record = described_class.new(version: "v3", items: [{ "id" => 1, "body" => "x" }])

    expect(JSON.generate(record.to_journal))
      .to eq('{"type":"memory_loaded","version":"v3","items":[{"body":"x","id":1}]}')
  end

  it "interns a non-String version" do
    expect(described_class.new(version: 3, items: []).version).to eq("3")
  end

  it "is shareable when built from mutable input" do
    expect(described_class.new(version: +"v3", items: [{ "body" => +"x" }])).to be_deeply_frozen
  end

  it "refuses a record naming no version" do
    expect { described_class.new(version: nil, items: []) }
      .to raise_error(ArgumentError, /version must name the store version/)
  end

  it "interns the version" do
    expect(described_class.new(version: +"v3", items: []).version)
      .to equal(described_class.new(version: +"v3", items: []).version)
  end
end
