# frozen_string_literal: true

RSpec.describe Lain::Event do
  def block(text) = [{ "type" => "text", "text" => text }]

  def payload(kind: :turn, body: { "role" => "user", "content" => block("hi") })
    Lain::Event::Payload.new(kind:, body:)
  end

  def event(kind: :turn, payload_digest: payload.digest, **rest)
    Lain::Event.new(kind:, payload_digest:, **rest)
  end

  describe "the closed kind set" do
    it "accepts each of the four legal kinds" do
      %i[turn spawn message snapshot].each do |kind|
        expect(event(kind:, payload_digest: "blake3:p").kind).to eq(kind)
      end
    end

    # AC: the kind set is closed and loud.
    it "raises a named error identifying the kind and listing the four legal kinds" do
      expect { event(kind: :banana, payload_digest: "blake3:p") }
        .to raise_error(Lain::Event::InvalidKind,
                        "kind must be one of turn, spawn, message, snapshot, got :banana")
    end

    it "coerces a String kind to the canonical Symbol" do
      expect(event(kind: "message", payload_digest: "blake3:p").kind).to eq(:message)
    end
  end

  describe "the envelope" do
    it "carries the direct-addressing and edge fields" do
      ev = event(kind: :message, payload_digest: "blake3:p", from: "orchestrator", to: "worker",
                 render_parent: "blake3:r", causal_parents: ["blake3:c"], correlation: "blake3:root")
      expect(ev).to have_attributes(kind: :message, from: "orchestrator", to: "worker",
                                    render_parent: "blake3:r", causal_parents: ["blake3:c"],
                                    correlation: "blake3:root", payload_digest: "blake3:p")
    end

    it "defaults every optional field so a bare event is well-formed" do
      ev = event(kind: :snapshot, payload_digest: "blake3:p")
      expect(ev).to have_attributes(from: nil, to: nil, render_parent: nil,
                                    causal_parents: [], correlation: nil)
    end
  end

  describe "#digest" do
    it "is a prefixed content address" do
      expect(event.digest).to start_with("blake3:")
    end

    # AC: identity is stable (Canonical bytes) -- two events built from the same
    # content name the same digest, in this or any other process.
    it "is stable across independent constructions of the same content" do
      one = event(kind: :message, payload_digest: "blake3:p", from: "a", to: "b",
                  render_parent: "blake3:r", causal_parents: %w[blake3:c1 blake3:c2])
      two = event(kind: :message, payload_digest: "blake3:p", from: "a", to: "b",
                  render_parent: "blake3:r", causal_parents: %w[blake3:c1 blake3:c2])
      expect(one.digest).to eq(two.digest)
    end

    it "distinguishes events that differ in any envelope field" do
      base = event(kind: :message, payload_digest: "blake3:p", from: "a")
      other = event(kind: :message, payload_digest: "blake3:p", from: "z")
      expect(base.digest).not_to eq(other.digest)
    end

    # Panel amendment: causal_parents is a SET -- insertion order must not leak
    # into identity, so it enters the digested bytes in sorted order. Ruby<->Rust
    # byte parity later depends on this pin.
    it "sorts causal_parents into the digested bytes, so insertion order does not change identity" do
      forward = event(payload_digest: "blake3:p", causal_parents: %w[blake3:a blake3:b blake3:c])
      shuffled = event(payload_digest: "blake3:p", causal_parents: %w[blake3:c blake3:a blake3:b])
      expect(forward.digest).to eq(shuffled.digest)
    end

    it "exposes causal_parents already sorted and deduplicated" do
      ev = event(payload_digest: "blake3:p", causal_parents: %w[blake3:c blake3:a blake3:a blake3:b])
      expect(ev.causal_parents).to eq(%w[blake3:a blake3:b blake3:c])
    end
  end

  describe "immutability" do
    subject(:ev) do
      event(kind: :message, payload_digest: "blake3:p", from: "a", to: "b",
            render_parent: "blake3:r", causal_parents: %w[blake3:c1 blake3:c2], correlation: "blake3:root")
    end

    it "is deeply frozen" do
      expect(ev).to be_deeply_frozen
    end

    # AC: Ractor.shareable?(event) is true -- the mechanical "no reachable mutable
    # state". String interpolation and Symbol#to_s both hand back mutable Strings.
    it "is deeply immutable, hence Ractor-shareable without make_shareable" do
      expect(ev).to be_ractor_shareable
    end

    it "freezes every instance variable" do
      unfrozen = ev.instance_variables.reject { |ivar| ev.instance_variable_get(ivar).frozen? }
      expect(unfrozen).to be_empty
    end
  end

  describe "Regular equality" do
    it "equates two events naming the same digest" do
      expect(event(payload_digest: "blake3:p")).to eq(event(payload_digest: "blake3:p"))
    end

    it "dedupes in a Set by digest" do
      set = Set.new([event(payload_digest: "blake3:p"), event(payload_digest: "blake3:p")])
      expect(set.size).to eq(1)
    end
  end

  # AC: payloads are content-addressed, never inline in the envelope.
  describe Lain::Event::Payload do
    it "is content-addressed and kind-tagged" do
      pay = payload(kind: :turn, body: { "role" => "user", "content" => block("hi") })
      expect(pay.digest).to start_with("blake3:")
      expect(pay.kind).to eq(:turn)
    end

    it "shares the envelope's closed, loud kind set" do
      expect { described_class.new(kind: :banana, body: {}) }
        .to raise_error(Lain::Event::InvalidKind, /got :banana/)
    end

    it "is deeply immutable, hence Ractor-shareable" do
      expect(payload).to be_ractor_shareable
    end

    it "the envelope references the payload by digest, and the payload is separately retrievable" do
      store = Lain::Store.new
      pay = payload(kind: :turn)
      store.put(pay)
      ev = event(kind: :turn, payload_digest: pay.digest)

      expect(ev.payload_digest).to eq(pay.digest)
      expect(store.fetch(ev.payload_digest)).to eq(pay)
    end
  end
end
