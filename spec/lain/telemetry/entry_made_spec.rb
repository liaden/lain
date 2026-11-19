# frozen_string_literal: true

# The record that the sandbox made an entry at a project's top, and the directory's ctime it left.
RSpec.describe Lain::Telemetry::EntryMade do
  subject(:record) { described_class.new(directory: "/srv/project", entry: "target", ctime: 1_700_000_000_123_456_789) }

  it "journals byte for byte with every field set" do
    expect(JSON.generate(record.to_journal))
      .to eq('{"type":"entry_made","directory":"/srv/project","entry":"target","ctime":1700000000123456789}')
  end

  it "reads back as the record it was written from" do
    expect(Lain::Telemetry.read(JSON.parse(JSON.generate(record.to_journal)))).to eq(record)
  end

  it "is deeply frozen when built from mutable input" do
    expect(described_class.new(directory: +"/srv/project", entry: +"target", ctime: 1)).to be_deeply_frozen
  end

  it "refuses a ctime that is not a whole number of nanoseconds" do
    expect { described_class.new(directory: "/srv/project", entry: "target", ctime: "soon") }
      .to raise_error(ArgumentError, /soon/)
  end
end
