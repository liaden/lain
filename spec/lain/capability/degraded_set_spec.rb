# frozen_string_literal: true

require "lain/capability/degraded_set"

RSpec.describe Lain::Capability::DegradedSet do
  it "is sorted, deduplicated, and symbolized regardless of input order" do
    set = described_class.new(%i[thinking server_tools thinking])
    expect(set.to_a).to eq(%i[server_tools thinking])
  end

  it "coerces string capabilities to symbols" do
    expect(described_class.new(%w[thinking]).to_a).to eq(%i[thinking])
  end

  it "is enumerable over its capabilities" do
    expect(described_class.new(%i[b a]).map(&:to_s)).to eq(%w[a b])
  end

  it "reports emptiness" do
    expect(described_class.new([])).to be_empty
    expect(described_class.new(%i[thinking])).not_to be_empty
  end

  it "has structural equality independent of construction order" do
    a = described_class.new(%i[thinking server_tools])
    b = described_class.new(%i[server_tools thinking])
    expect(a).to eq(b)
    expect(a.hash).to eq(b.hash)
  end

  it "is a deeply frozen, Ractor-shareable value object" do
    set = described_class.new(%i[thinking server_tools])
    expect(set).to be_frozen
    expect(Ractor.shareable?(set)).to be(true)
  end
end
