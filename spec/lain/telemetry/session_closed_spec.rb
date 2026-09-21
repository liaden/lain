# frozen_string_literal: true

require "json"

# An additive session-record type, its discriminator pinned here as the on-disk
# contract -- additive by construction, so the turn-chain loader's `of_type`
# narrowing skips it and an older reader stays unaffected.
RSpec.describe Lain::Telemetry::SessionClosed do
  it "journals as session_closed carrying the head anchor and the reason" do
    event = described_class.new(head: "blake3:abc", reason: :exit)
    expect(event.journal_type).to eq("session_closed")
    expect(event.to_journal).to eq("type" => "session_closed", "head" => "blake3:abc", "reason" => :exit)
    expect(JSON.parse(JSON.generate(event.to_journal)))
      .to include("type" => "session_closed", "reason" => "exit")
  end

  it "pins the reason enum, rejecting anything outside it, echoing the offender" do
    expect(described_class::REASONS).to eq(%i[exit interrupted grace_expired salvaged])
    expect { described_class.new(head: nil, reason: :kaput) }
      .to raise_error(ArgumentError,
                      "reason must be one of [:exit, :interrupted, :grace_expired, :salvaged], got :kaput")
  end

  # nil is not a hypothetical offender: it is what `record["reason"]&.to_sym`
  # hands a reconstruction of a line written before the field existed, and it
  # has to arrive as the enum's refusal rather than a NoMethodError from inside
  # the guard. Pinned on BOTH lifecycle enums, which are deliberately identical.
  it "refuses a nil reason as the enum's own ArgumentError, not a NoMethodError" do
    expect { described_class.new(head: nil, reason: nil) }
      .to raise_error(ArgumentError,
                      "reason must be one of [:exit, :interrupted, :grace_expired, :salvaged], got nil")
  end

  it "tolerates a nil head (a session that committed nothing) and stays a frozen value" do
    event = described_class.new(head: nil, reason: :interrupted)
    expect(event.head).to be_nil
    expect(event).to be_deeply_frozen
  end
end
