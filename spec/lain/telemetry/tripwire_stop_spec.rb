# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::TripwireStop do
  def stop(**overrides)
    described_class.new(requester: "researcher", signal: "refused_exec", outcome: :stopped,
                        unseeded: ["remembered_reask"], **overrides)
  end

  it "journals its fields and nothing else, with no empty value" do
    expect(stop.to_journal).to eq("type" => "tripwire_stop", "requester" => "researcher", "signal" => "refused_exec",
                                  "outcome" => "stopped", "unseeded" => ["remembered_reask"])
  end

  it "is shareable across Ractors, even built from mutable input" do
    expect(Ractor.shareable?(stop(requester: +"researcher", unseeded: [+"remembered_reask"]))).to be(true)
  end

  it "journals byte for byte, the observe-only outcome included" do
    record = described_class.new(requester: "r", signal: "s", outcome: described_class::OBSERVE_ONLY,
                                 unseeded: %w[a b])

    expect(JSON.generate(record.to_journal))
      .to eq('{"type":"tripwire_stop","requester":"r","signal":"s","outcome":"observe_only","unseeded":["a","b"]}')
  end

  it "shares the bytes of every interned field between 2 equal records" do
    build = lambda do
      described_class.new(requester: +"r", signal: +"s", outcome: +"stopped", unseeded: [+"a", +"b"])
    end
    one = build.call
    other = build.call

    expect([one.requester, one.signal, one.outcome].zip([other.requester, other.signal, other.outcome])
      .map { |left, right| left.equal?(right) }).to eq([true, true, true])
    expect(one.unseeded.zip(other.unseeded).map { |left, right| left.equal?(right) }).to eq([true, true])
  end

  it "stores a Symbol outcome as its string and takes any outcome, leaving the set to the ledger" do
    expect(stop(outcome: :all_stopped).outcome).to eq("all_stopped")
    expect(stop(outcome: "anything").outcome).to eq("anything")
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { stop(extra: 1) }.to raise_error(ArgumentError, /extra/)
  end
end
