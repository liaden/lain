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

  it "names the spawn whose child paid, and leaves the key out for the run's own payment" do
    child = described_class.new(digest: "blake3:abc123", model: nil, stop_reason: :end_turn, usage: {},
                                spawn: "blake3:spawn")

    expect([child.to_journal["spawn"], event.spawn, event.to_journal.key?("spawn")])
      .to eq(["blake3:spawn", nil, false])
    expect(child).to be_deeply_frozen
  end

  describe "journal bytes" do
    let(:usage) { { input_tokens: 10 } }

    it "prints the spawn key when a child paid" do
      record = described_class.new(digest: "blake3:abc", model: "claude", stop_reason: :end_turn, usage:,
                                   spawn: "blake3:spawn")

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"turn_usage","digest":"blake3:abc","model":"claude","stop_reason":"end_turn",' \
        '"usage":{"input_tokens":10},"spawn":"blake3:spawn"}'
      )
    end

    it "leaves the spawn key out for the run own payment" do
      record = described_class.new(digest: "blake3:abc", model: "claude", stop_reason: :end_turn, usage:)

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"turn_usage","digest":"blake3:abc","model":"claude","stop_reason":"end_turn",' \
        '"usage":{"input_tokens":10}}'
      )
    end

    it "prints a null model" do
      record = described_class.new(digest: "blake3:abc", model: nil, stop_reason: :end_turn, usage: {})

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"turn_usage","digest":"blake3:abc","model":null,"stop_reason":"end_turn","usage":{}}'
      )
    end
  end

  describe "the requester" do
    let(:judged) do
      described_class.new(digest: "blake3:req", model: "m", stop_reason: :end_turn, usage: {},
                          requester: :auto_approver)
    end

    it "names who paid when it was not the agent, and leaves the key out for the agent's own" do
      expect([judged.to_journal["requester"], event.requester, event.to_journal.key?("requester")])
        .to eq(["auto_approver", nil, false])
      expect(judged).to be_deeply_frozen
    end

    it "reads a record with no requester, or the agent's, as the agent's own" do
      records = [event, judged, event.with(requester: "agent")].map { JSON.parse(JSON.generate(_1.to_journal)) }

      expect(records.map { described_class.agent?(_1) }).to eq([true, false, true])
    end

    it "answers the same of the record itself" do
      expect([event.agent?, judged.agent?]).to eq([true, false])
    end
  end

  describe "interning and refusals" do
    def fresh(**extra)
      described_class.new(digest: +"blake3:abc", model: +"m", stop_reason: :end_turn, usage: {}, spawn: +"s", **extra)
    end

    it "interns spawn across equal records" do
      expect(fresh.spawn).to equal(fresh.spawn)
    end

    it "refuses an unknown keyword and a missing usage with ArgumentError" do
      expect { fresh(bogus: 1) }.to raise_error(ArgumentError)
      expect { described_class.new(digest: "d", model: nil, stop_reason: :end_turn) }.to raise_error(ArgumentError)
    end
  end
end
