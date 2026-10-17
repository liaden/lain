# frozen_string_literal: true

require "json"

# One lineage a consolidation pass worked, and how it ended.
RSpec.describe Lain::Telemetry::ConsolidationLineage do
  subject(:record) do
    described_class.new(spawn: "blake3:aa", spawned_from: "blake3:bb", turn_count: 3, wrote: true, failure: nil)
  end

  it "carries the spawn, spawned_from, turn_count, wrote, and a nil failure" do
    expect(record).to have_attributes(spawn: "blake3:aa", spawned_from: "blake3:bb", turn_count: 3, wrote: true,
                                      failure: nil)
  end

  it "carries a failure as its stop reason and message, both Strings" do
    failed = described_class.new(spawn: "blake3:aa", spawned_from: "blake3:bb", turn_count: 3, wrote: false,
                                 failure: Lain::Response::Failure.new(stop_reason: :ceiling, message: "too long"))

    expect(failed.failure).to eq("stop_reason" => "ceiling", "message" => "too long")
  end

  it "journals as a consolidation_lineage record that round-trips through JSON" do
    expect(record.journal_type).to eq("consolidation_lineage")
    expect(JSON.parse(JSON.generate(record.to_journal))).to eq(
      "type" => "consolidation_lineage", "spawn" => "blake3:aa", "spawned_from" => "blake3:bb",
      "turn_count" => 3, "wrote" => true, "failure" => nil
    )
  end

  it "is a frozen value object with structural equality, Ractor-shareable from mutable input" do
    mutable = described_class.new(spawn: +"blake3:aa", spawned_from: +"blake3:bb", turn_count: 3, wrote: true,
                                  failure: nil)

    expect(mutable).to eq(record)
    expect(mutable).to be_deeply_frozen
    expect(mutable).to be_deeply_frozen
  end

  it "rejects a nil spawn loudly" do
    expect { described_class.new(spawn: nil, spawned_from: "b", turn_count: 1, wrote: false, failure: nil) }
      .to raise_error(ArgumentError, /spawn must name the lineage, got nil/)
  end

  it "rejects a wrote that is not a boolean, since false is the value that matters" do
    expect { described_class.new(spawn: "a", spawned_from: "b", turn_count: 1, wrote: nil, failure: nil) }
      .to raise_error(ArgumentError, /wrote must be true or false/)
  end
end
