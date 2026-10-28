# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::AskSettled do
  subject(:event) { described_class.new(head: "sha-head", stop_reason: :end_turn, turns: 2, seconds: 1.5) }

  it "carries the head, stop reason, turn count and elapsed seconds" do
    expect(event).to have_attributes(head: "sha-head", stop_reason: "end_turn", turns: 2, seconds: 1.5)
  end

  it "journals byte for byte as an ask_settled record" do
    expect(JSON.generate(event.to_journal)).to eq(
      '{"type":"ask_settled","head":"sha-head","stop_reason":"end_turn","turns":2,"seconds":1.5}'
    )
  end

  it "is deeply frozen when built from mutable input" do
    expect(described_class.new(head: +"sha-head", stop_reason: +"end_turn", turns: 2, seconds: 1.5)).to be_deeply_frozen
  end

  it "refuses a missing head, naming it" do
    expect { described_class.new(stop_reason: :end_turn, turns: 2, seconds: 1.5) }.to raise_error(ArgumentError, /head/)
  end
end
