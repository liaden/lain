# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Dropped do
  it "carries a positive count" do
    expect(described_class.new(count: 3).count).to eq(3)
  end

  it "rejects a non-positive count" do
    expect { described_class.new(count: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(count: -1) }.to raise_error(ArgumentError)
  end

  it "is a frozen value object" do
    expect(described_class.new(count: 1)).to be_deeply_frozen
  end

  it "journals as a dropped marker" do
    expect(described_class.new(count: 5).to_journal).to eq("type" => "dropped", "count" => 5)
  end
end
