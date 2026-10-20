# frozen_string_literal: true

# The Rust event built for every kind, not only :turn: the digest is the Ruby
# envelope's to the byte, and an unknown kind is refused as loudly as Ruby does.
RSpec.describe Lain::Ext::Event do
  let(:body) { { "x" => 1, "note" => "hi" } }

  def ruby_event(kind, **fields)
    payload = Lain::Event::Payload.new(kind:, body:)
    Lain::Event.new(kind:, carried_payload: payload, **fields)
  end

  Lain::EventLog::Kinds::KINDS.each do |kind|
    it "digests a #{kind} event to the Ruby digest" do
      fields = { from: "alice", to: "bob", render_parent: "blake3:p", causal_parents: %w[blake3:b blake3:a],
                 correlation: "blake3:root" }
      expect(described_class.new(kind:, body:, **fields).digest).to eq(ruby_event(kind, **fields).digest)
    end

    it "reports the #{kind} kind and its payload digest" do
      event = described_class.new(kind:, body:)
      expect([event.kind, event.payload_digest]).to eq([kind, ruby_event(kind).payload_digest])
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

  # Ruby raises here; a body is enough to address the payload, so Rust builds it.
  it "builds the payload from a body with no digest" do
    event = described_class.new(kind: :message, body:)
    expect(event.payload_digest).to eq(ruby_event(:message).payload_digest)
  end

  it "accepts a payload_digest that agrees with the body" do
    digest = ruby_event(:message).payload_digest
    expect(described_class.new(kind: :message, body:, payload_digest: digest).payload_digest).to eq(digest)
  end

  it "refuses a payload_digest that disagrees with the body, naming both" do
    expect { described_class.new(kind: :message, body:, payload_digest: "blake3:zz") }
      .to raise_error(ArgumentError, /blake3:zz.*#{Regexp.escape(ruby_event(:message).payload_digest)}/)
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

  it "reads Symbol from and to as Ruby does" do
    ruby = ruby_event(:message, from: "alice", to: "bob")
    expect(described_class.new(kind: :message, body:, from: :alice, to: :bob).digest).to eq(ruby.digest)
  end

  it "stays an alias of the turn class" do
    expect(described_class).to equal(Lain::Ext::Turn)
  end

  it "still builds a turn from a role and content" do
    expect(described_class.new(role: :user, content: []).kind).to eq(:turn)
  end
end
