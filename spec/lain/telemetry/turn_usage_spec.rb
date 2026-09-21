# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::TurnUsage do
  subject(:event) do
    described_class.new(digest: "blake3:abc123", model: "claude-opus-4-8",
                        stop_reason: :end_turn,
                        usage: { input_tokens: 10, output_tokens: 5 })
  end

  it "carries the turn digest, model, stop_reason, and usage" do
    expect(event.digest).to eq("blake3:abc123")
    expect(event.model).to eq("claude-opus-4-8")
    expect(event).to stop_with(:end_turn)
    expect(event.usage).to eq("input_tokens" => 10, "output_tokens" => 5)
  end

  it "normalizes usage to canonical wire form, so symbol- and string-keyed input are the same event" do
    twin = described_class.new(digest: "blake3:abc123", model: "claude-opus-4-8",
                               stop_reason: :end_turn,
                               usage: { "input_tokens" => 10, "output_tokens" => 5 })
    expect(event).to eq(twin)
    expect(event.hash).to eq(twin.hash)
  end

  it "is deeply frozen, usage hash included" do
    expect(event).to be_deeply_frozen
  end

  it "rejects a nil stop_reason loudly" do
    expect { described_class.new(digest: "blake3:abc123", model: nil, stop_reason: nil, usage: {}) }
      .to raise_error(ArgumentError, /stop_reason/)
  end

  it "rejects a nil digest loudly -- a payment must name the turn it paid for" do
    expect { described_class.new(digest: nil, model: nil, stop_reason: :end_turn, usage: {}) }
      .to raise_error(ArgumentError, /digest must name the committed turn/)
  end

  it "tolerates a nil model, because a bare mock response carries none" do
    bare = described_class.new(digest: "blake3:abc123", model: nil,
                               stop_reason: :end_turn, usage: {})
    expect(bare.model).to be_nil
    expect(bare).to be_deeply_frozen
  end

  it "journals as a turn_usage record that round-trips through JSON" do
    expect(event.to_journal).to eq(
      "type" => "turn_usage", "digest" => "blake3:abc123",
      "model" => "claude-opus-4-8", "stop_reason" => :end_turn,
      "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
    )
    expect(JSON.parse(JSON.generate(event.to_journal))).to include(
      "type" => "turn_usage", "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
    )
  end
end
