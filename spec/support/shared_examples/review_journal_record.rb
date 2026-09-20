# frozen_string_literal: true

require "stringio"

# What every one of the review surface's six journal records is held to in
# common. They are Journalable Data values like any other Lain::Telemetry
# event, and their `type` strings are DURABLE discriminators a later reader
# joins on, so every one is pinned as a literal by its caller rather than
# derived -- a spec that recomputed `underscore` would agree with a rename that
# broke every recorded journal.
RSpec.shared_examples "a review journal record" do |discriminator|
  it "journals under the underscored basename of its class" do
    expect(record.journal_type).to eq(discriminator)
    expect(described_class::JOURNAL_TYPE).to eq(discriminator)
  end

  # The strong form: not `include`, but the whole record back. The
  # reconstruction is the half that catches a member the wire cannot carry -- a
  # Symbol side journals as a String, and a record that cannot be rebuilt from
  # its own line is one no session can replay.
  it "round-trips through a real journal, unchanged" do
    io = StringIO.new
    Lain::Journal.new(io:).record(record)

    parsed = Lain::Journal.records(io.string.lines, type: discriminator).to_a

    expect(parsed.size).to eq(1)
    expect(parsed.first.except("ts")).to eq(record.to_journal)
    expect(described_class.new(**parsed.first.except("ts", "type").transform_keys(&:to_sym))).to eq(record)
  end

  it "is a deeply frozen, shareable value" do
    expect(record).to be_deeply_frozen
  end
end
