# frozen_string_literal: true

# The event built for every kind, not only :turn, and an unknown kind refused
# loudly. Every envelope digest is pinned by the conformance corpus
# (ext/lain/corpus/event_digest.ndjson); a payload's is stated here through
# Canonical, which addresses the kind and the body together.
RSpec.describe Lain::Ext::Event do
  let(:body) { { "x" => 1, "note" => "hi" } }

  def payload_digest(kind) = Lain::Canonical.digest({ "kind" => kind, "body" => body })

  Lain::EventLog::Kinds::KINDS.each do |kind|
    it "reports the #{kind} kind and its payload digest" do
      event = described_class.new(kind:, body:)
      expect([event.kind, event.payload_digest]).to eq([kind, payload_digest(kind)])
    end
  end

  it "hands the body back" do
    expect(described_class.new(kind: :message, body:).body).to eq(body)
  end

  it "accepts a kind named by String" do
    expect(described_class.new(kind: "snapshot", body:).kind).to eq(:snapshot)
  end

  it "refuses an unknown kind, listing the kinds" do
    expect { described_class.new(kind: :bogus, body:) }
      .to raise_error(Lain::Error, /kind must be one of turn, spawn, message, snapshot, got :bogus/)
  end

  it "refuses an envelope with no payload" do
    expect { described_class.new(kind: :message) }.to raise_error(ArgumentError, /payload/)
  end

  # A body is enough to address the payload, so no digest need be passed.
  it "builds the payload from a body with no digest" do
    event = described_class.new(kind: :message, body:)
    expect(event.payload_digest).to eq(payload_digest(:message))
  end

  it "accepts a payload_digest that agrees with the body" do
    digest = payload_digest(:message)
    expect(described_class.new(kind: :message, body:, payload_digest: digest).payload_digest).to eq(digest)
  end

  it "refuses a payload_digest that disagrees with the body, naming both" do
    expect { described_class.new(kind: :message, body:, payload_digest: "blake3:zz") }
      .to raise_error(ArgumentError, /blake3:zz.*#{Regexp.escape(payload_digest(:message))}/)
  end

  it "builds from another event's carried payload of the same kind" do
    source = described_class.new(kind: :spawn, body:)
    event = described_class.new(kind: :spawn, carried_payload: source.carried_payload, from: "a")
    expect(event.payload_digest).to eq(source.payload_digest)
  end

  it "refuses a carried payload of another kind" do
    source = described_class.new(kind: :spawn, body:)
    expect { described_class.new(kind: :message, carried_payload: source.carried_payload) }
      .to raise_error(ArgumentError, /kind/)
  end

  it "addresses a Symbol from and to as their Strings" do
    spelled = described_class.new(kind: :message, body:, from: "alice", to: "bob")
    expect(described_class.new(kind: :message, body:, from: :alice, to: :bob).digest).to eq(spelled.digest)
  end

  it "still builds a turn from a role and content" do
    expect(described_class.new(role: :user, content: []).kind).to eq(:turn)
  end
end
