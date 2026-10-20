# frozen_string_literal: true

require "json"

# What a memory_read whose body was masked leaves in the Journal.
RSpec.describe Lain::Telemetry::MemoryMasked do
  subject(:event) { described_class.new(tool_use_id: "tu_9", id: "db-creds", regions: 2) }

  it "carries the tool_use_id, the memory id and the count of masked spans" do
    expect(event).to have_attributes(tool_use_id: "tu_9", id: "db-creds", regions: 2, prior: 0)
  end

  it "carries the count of placeholders already present" do
    expect(described_class.new(tool_use_id: "tu_9", id: "db-creds", regions: 2, prior: 3)).to have_attributes(prior: 3)
  end

  it "is a frozen value object, shareable even from mutable Strings" do
    expect(described_class.new(tool_use_id: +"tu_9", id: +"db-creds", regions: 2)).to be_deeply_frozen
  end

  it "journals as a memory_masked record holding the id and a count only" do
    expect(event.to_journal).to eq("type" => "memory_masked", "tool_use_id" => "tu_9", "id" => "db-creds",
                                   "regions" => 2, "prior" => 0)
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq(event.to_journal)
  end

  it "rejects a record that names no memory id, since replay refuses rewrites by it" do
    [nil, ""].each do |bad|
      expect { described_class.new(tool_use_id: "tu_9", id: bad, regions: 1) }.to raise_error(ArgumentError, /id/)
    end
  end

  it "rejects a count that is not a non-negative Integer" do
    [nil, -1, 1.5, { "leaked" => "bytes" }].each do |bad|
      expect { described_class.new(tool_use_id: "tu_9", id: "db-creds", regions: bad) }
        .to raise_error(ArgumentError, /regions/)
      expect { described_class.new(tool_use_id: "tu_9", id: "db-creds", regions: 1, prior: bad) }
        .to raise_error(ArgumentError, /prior/)
    end
  end
end
