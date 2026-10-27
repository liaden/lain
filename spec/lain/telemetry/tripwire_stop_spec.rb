# frozen_string_literal: true

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
end
