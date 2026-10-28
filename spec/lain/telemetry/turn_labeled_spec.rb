# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::TurnLabeled do
  it "journals as a turn_labeled record naming the digest and the text" do
    event = described_class.new(digest: "blake3:aaaa1111", label: "before refactor")

    expect(JSON.generate(event.to_journal)).to eq(
      '{"type":"turn_labeled","digest":"blake3:aaaa1111","label":"before refactor"}'
    )
  end

  it "accepts an empty label, which is how a label is cleared" do
    expect(described_class.new(digest: "blake3:aaaa1111", label: "").label).to eq("")
  end

  it "is deeply frozen when built from mutable input" do
    expect(described_class.new(digest: +"blake3:aaaa1111", label: +"x")).to be_deeply_frozen
  end

  it "refuses a missing digest, naming it" do
    expect { described_class.new(label: "x") }.to raise_error(ArgumentError, /digest/)
  end

  it "refuses a blank digest" do
    expect { described_class.new(digest: " ", label: "x") }.to raise_error(ArgumentError, /digest/)
  end
end
