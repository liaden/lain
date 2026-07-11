# frozen_string_literal: true

require "json"

require "lain/event"

RSpec.describe Lain::Event do
  describe Lain::Event::ToolOutput do
    subject(:event) { described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi") }

    it "rejects an unknown stream" do
      expect { described_class.new(tool_use_id: "t", stream: :nope, bytes: "x") }
        .to raise_error(ArgumentError)
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi")
      expect(event).to eq(twin)
      expect(event).to be_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(Ractor.shareable?(event)).to be(true)
    end

    describe "#to_journal" do
      it "is a JSON object of the attributes tagged with a snake_case type" do
        expect(event.to_journal).to eq(
          "type" => "tool_output", "tool_use_id" => "t1", "stream" => :stdout, "bytes" => "hi"
        )
      end

      it "round-trips through JSON to a parseable line" do
        expect(JSON.parse(JSON.generate(event.to_journal))).to include(
          "type" => "tool_output", "stream" => "stdout"
        )
      end
    end
  end

  describe Lain::Event::Dropped do
    it "carries a positive count" do
      expect(described_class.new(count: 3).count).to eq(3)
    end

    it "rejects a non-positive count" do
      expect { described_class.new(count: 0) }.to raise_error(ArgumentError)
      expect { described_class.new(count: -1) }.to raise_error(ArgumentError)
    end

    it "is a frozen value object" do
      expect(described_class.new(count: 1)).to be_frozen
    end

    it "journals as a dropped marker" do
      expect(described_class.new(count: 5).to_journal).to eq("type" => "dropped", "count" => 5)
    end
  end

  describe Lain::Event::TurnUsage do
    subject(:event) do
      described_class.new(digest: "blake3:abc123", model: "claude-opus-4-8",
                          stop_reason: :end_turn,
                          usage: { input_tokens: 10, output_tokens: 5 })
    end

    it "carries the turn digest, model, stop_reason, and usage" do
      expect(event.digest).to eq("blake3:abc123")
      expect(event.model).to eq("claude-opus-4-8")
      expect(event.stop_reason).to eq(:end_turn)
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
      expect(event).to be_frozen
      expect(event.usage).to be_frozen
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(Ractor.shareable?(event)).to be(true)
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
      expect(Ractor.shareable?(bare)).to be(true)
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

  describe Lain::Event::CapabilityDegraded do
    subject(:event) do
      described_class.new(capability: :thinking, requirer: "Prune", provider: "Provider::Mock")
    end

    it "carries the capability, requirer, and provider" do
      expect(event.capability).to eq(:thinking)
      expect(event.requirer).to eq("Prune")
      expect(event.provider).to eq("Provider::Mock")
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(capability: :thinking, requirer: "Prune", provider: "Provider::Mock")
      expect(event).to eq(twin)
      expect(event).to be_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(Ractor.shareable?(event)).to be(true)
    end

    it "journals as a capability_degraded record that round-trips through JSON" do
      expect(event.to_journal).to eq(
        "type" => "capability_degraded", "capability" => :thinking,
        "requirer" => "Prune", "provider" => "Provider::Mock"
      )
      expect(JSON.parse(JSON.generate(event.to_journal))).to include(
        "type" => "capability_degraded", "capability" => "thinking"
      )
    end
  end
end
