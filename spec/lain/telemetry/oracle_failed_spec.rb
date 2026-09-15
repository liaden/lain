# frozen_string_literal: true

require "json"

# Journaled by {Oracle::Recorded::Journaling} beside the {Telemetry::RequestSent}
# its inner tier already wrote, so a failed oracle call names itself rather than
# reading only as an answer that never arrived. See
# `spec/lain/oracle/recorded_spec.rb` for the write path; this pins the record's
# own shape.
RSpec.describe Lain::Telemetry::OracleFailed do
  subject(:event) do
    described_class.new(tier: :model, oracle_digest: "digest-abc", error_class: "Lain::Oracle::UndecodableAnswer")
  end

  it "is a frozen, Ractor-shareable value with structural equality" do
    twin = described_class.new(tier: :model, oracle_digest: +"digest-abc",
                               error_class: +"Lain::Oracle::UndecodableAnswer")
    expect(event).to eq(twin)
    expect(event.hash).to eq(twin.hash)
    expect(event).to be_deeply_frozen
  end

  describe "#to_journal" do
    it "tags itself oracle_failed and names the tier, the oracle, and what broke" do
      expect(event.to_journal).to eq(
        "type" => "oracle_failed", "tier" => :model, "oracle_digest" => "digest-abc",
        "error_class" => "Lain::Oracle::UndecodableAnswer"
      )
    end

    it "round-trips through JSON to a parseable line" do
      expect(JSON.parse(JSON.generate(event.to_journal)))
        .to eq("type" => "oracle_failed", "tier" => "model", "oracle_digest" => "digest-abc",
               "error_class" => "Lain::Oracle::UndecodableAnswer")
    end
  end

  # `error_class` is a NAME, never the class object -- a raw Class has no
  # canonical JSON form and would make the record fail Ractor.shareable?.
  it "coerces a Symbol tier and stores the error class as its name String" do
    from_error = described_class.new(tier: :heuristic, oracle_digest: "d",
                                     error_class: Lain::Oracle::UndecodableAnswer.name)

    expect(from_error.tier).to eq(:heuristic)
    expect(from_error.error_class).to eq("Lain::Oracle::UndecodableAnswer")
  end

  # Loud failure, the same validate-then-freeze contract every sibling record
  # has. A record naming no tier, no oracle, or no error would journal a blank
  # line that reads as a finding with nothing to check it against.
  it "refuses a record that names no tier, no oracle, or no error" do
    expect(Lain::Telemetry::Carriers::OracleFailed.new(tier: nil, oracle_digest: nil, error_class: nil))
      .to be_invalid
    expect { described_class.new(tier: nil, oracle_digest: "d", error_class: "Boom") }
      .to raise_error(ArgumentError, /tier must name the oracle's tier/)
    expect { described_class.new(tier: :model, oracle_digest: nil, error_class: "Boom") }
      .to raise_error(ArgumentError, /oracle_digest must name the oracle that failed/)
    expect { described_class.new(tier: :model, oracle_digest: "d", error_class: nil) }
      .to raise_error(ArgumentError, /error_class must name what broke/)
  end
end
