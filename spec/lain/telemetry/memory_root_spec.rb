# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::MemoryRoot do
  subject(:event) { described_class.new(turn_digest: "blake3:turn", root: "blake3:root") }

  it "carries the committed turn's digest and the index root in force at it" do
    expect(event.turn_digest).to eq("blake3:turn")
    expect(event.root).to eq("blake3:root")
  end

  it "is a frozen value object with structural equality" do
    twin = described_class.new(turn_digest: "blake3:turn", root: "blake3:root")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
    expect(event.hash).to eq(twin.hash)
  end

  it "is Ractor-shareable even when built from mutable Strings" do
    mutable = described_class.new(turn_digest: +"blake3:turn", root: +"blake3:root")
    expect(mutable).to be_deeply_frozen
  end

  it "rejects a nil turn_digest loudly" do
    expect { described_class.new(turn_digest: nil, root: "blake3:root") }
      .to raise_error(ArgumentError, /turn_digest/)
  end

  it "tolerates a nil root, because an empty index has no root node to name" do
    bare = described_class.new(turn_digest: "blake3:turn", root: nil)
    expect(bare.root).to be_nil
    expect(bare).to be_deeply_frozen
  end

  it "journals as a memory_root record whose nil root round-trips as JSON null" do
    expect(event.to_journal).to eq(
      "type" => "memory_root", "turn_digest" => "blake3:turn", "root" => "blake3:root"
    )

    bare = described_class.new(turn_digest: "blake3:turn", root: nil)
    line = JSON.generate(bare.to_journal)
    expect(line).to include('"root":null')
    expect(JSON.parse(line)).to include("type" => "memory_root", "root" => nil)
  end
end
