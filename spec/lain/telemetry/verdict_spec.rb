# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::Verdict do
  let(:fields) { { digest: "blake3:abc", survived: true, score: 0.9, why: "holds" } }

  it "journals the scale it was judged on" do
    record = described_class.new(**fields, scale: :three)

    expect(JSON.parse(JSON.generate(record.to_journal))).to include("type" => "verdict", "scale" => "three")
  end

  it "reads an old record with no scale as unattributed" do
    expect(described_class.new(**fields).scale).to be_nil
  end

  it "stays deeply frozen with a scale" do
    expect(described_class.new(**fields, scale: +"three")).to be_deeply_frozen
  end

  it "journals the index of the refuter that judged it" do
    record = described_class.new(**fields, refuter: 2)

    expect(JSON.parse(JSON.generate(record.to_journal))).to include("refuter" => 2)
  end

  it "reads an old record with no refuter as unindexed, and stays shareable" do
    record = described_class.new(**fields)

    expect(record.refuter).to be_nil
    expect(Ractor.shareable?(record)).to be(true)
    expect(Ractor.shareable?(described_class.new(**fields, refuter: 1))).to be(true)
  end
end
