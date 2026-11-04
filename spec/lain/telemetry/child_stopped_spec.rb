# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ChildStopped do
  let(:stopped) do
    described_class.new(spawn: "blake3:spawn", label: "skeleton", role: "dev", head: "blake3:head",
                        lease_path: "/w/children/4bfe", ceiling: 20, reason: :iterations, snapshot: "c0ffee",
                        task: "build the skeleton", parent: "blake3:chat", kept: false)
  end

  it "reads back from its journal line as the record it was written from" do
    line = JSON.parse(JSON.generate(stopped.to_journal))

    expect(line["type"]).to eq("child_stopped")
    expect(Lain::Telemetry.read(line)).to eq(stopped)
  end

  it "journals its reason as one of the stops a resume answers" do
    expect(described_class::REASONS).to eq(%w[iterations transport interrupted])
    expect(stopped.reason).to eq("iterations")
  end

  it "leaves where the child worked unnamed when it worked in no checkout of its own" do
    bare = described_class.new(spawn: "blake3:spawn", label: "notes", head: "blake3:head", reason: :interrupted)

    expect(bare).to have_attributes(role: nil, lease_path: nil, ceiling: nil, snapshot: nil, parent: nil, kept: false)
  end

  it "refuses a stop that names no spawn" do
    expect { described_class.new(spawn: nil, label: "x", head: "blake3:h", reason: :transport) }
      .to raise_error(ArgumentError, /spawn/)
  end

  it "is built by the journalable sweep's generic dummies, so the registry sweeps cover it" do
    expect(GenericBuild.build(described_class)).to be_a(described_class)
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(stopped)).to be(true)
  end
end
