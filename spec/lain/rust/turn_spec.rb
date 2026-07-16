# frozen_string_literal: true

# The Rust Turn behind the same duck as `Lain::Turn`: it drives the shared
# `regular` group, keeps `Ractor.shareable?` true (the real acceptance test for
# the port), and -- the cross-check that makes the port meaningful -- produces a
# digest byte-identical to the Ruby Turn for the same inputs.
RSpec.describe Lain::Ext::Turn do
  def text(body) = [{ "type" => "text", "text" => body }]

  describe "construction" do
    it "rejects any non-wire role" do
      expect { described_class.new(role: "system", content: text("x")) }
        .to raise_error(described_class::InvalidRole, /must be one of/)
    end

    it "accepts a Symbol role" do
      expect(described_class.new(role: :user, content: text("x")).role).to eq("user")
    end

    it "is a root when it has no parent" do
      expect(described_class.new(role: :user, content: text("x"))).to be_root
    end
  end

  describe "content" do
    it "stores content in normalized wire form" do
      turn = described_class.new(role: :user, content: [{ type: :text, text: "hi" }])
      expect(turn.content).to eq([{ "type" => "text", "text" => "hi" }])
    end

    it "deeply freezes content" do
      turn = described_class.new(role: :user, content: text("hi"))
      expect(turn.content).to be_deeply_frozen
    end

    it "freezes the turn itself" do
      expect(described_class.new(role: :user, content: text("hi"))).to be_deeply_frozen
    end

    # The whole reason the port is allowed: a magnus TypedData wrapping only
    # immutable Rust state stays Ractor-shareable once frozen.
    it "is Ractor-shareable" do
      turn = described_class.new(role: :user, content: text("hi"), meta: { "a" => 1 })
      expect(turn).to be_ractor_shareable
    end

    it "has no unfrozen instance variables" do
      turn = described_class.new(role: :user, content: text("hi"))
      unfrozen = turn.instance_variables.reject { |ivar| turn.instance_variable_get(ivar).frozen? }
      expect(unfrozen).to be_empty
    end
  end

  describe "#digest" do
    it "is a prefixed content address" do
      expect(described_class.new(role: :user, content: text("hi")).digest).to start_with("blake3:")
    end

    it "changes with role, content, parent, and meta" do
      base = described_class.new(role: :user, content: text("hi"))
      expect(base).not_to have_same_digest_as(described_class.new(role: :assistant, content: text("hi")))
      expect(base).not_to have_same_digest_as(described_class.new(role: :user, content: text("bye")))
      expect(base).not_to have_same_digest_as(
        described_class.new(role: :user, content: text("hi"), parent: "blake3:abc")
      )
      expect(base).not_to have_same_digest_as(
        described_class.new(role: :user, content: text("hi"), meta: { "s" => "x" })
      )
    end

    # The port is only correct if its content address equals the Ruby Turn's to
    # the byte, over the same inputs -- including parent and meta.
    it "equals the Ruby Turn digest byte-for-byte" do
      pending "TL-2 collapsed the Ruby Turn into Event(kind: :turn), re-keying the Ruby digest scheme; " \
              "this crate still hashes the old TurnData shape, so Ruby<->Rust digest parity returns with " \
              "T25 (the Rust re-port of the event envelope)"
      ext = described_class.new(role: :user, content: text("hi"),
                                parent: "blake3:abc", meta: { "spawned_from" => "blake3:xyz" })
      ruby = Lain::Event.turn(role: :user, content: text("hi"),
                              parent: "blake3:abc", meta: { "spawned_from" => "blake3:xyz" })
      expect(ext).to have_same_digest_as(ruby)
    end
  end

  describe "#payload" do
    # payload is on the duck (Lain::Event#payload) and is the exact structure the
    # digest is taken over -- pin it against the Ruby value, not just the digest.
    it "equals the Ruby payload byte-for-byte" do
      pending "TL-2 moved the Ruby hashed structure to the Event envelope (kind/edges/correlation/" \
              "payload_digest); this crate still exposes the old TurnData payload, so byte parity " \
              "returns with T25 (the Rust re-port of the event envelope)"
      args = { role: :user, content: text("hi"),
               parent: "blake3:abc", meta: { "spawned_from" => "blake3:xyz" } }
      expect(described_class.new(**args).payload).to eq(Lain::Event.turn(**args).payload)
    end
  end

  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: lambda {
                       [described_class.new(role: :user, content: text("hi")),
                        described_class.new(role: :user, content: text("hi"))]
                     },
                     unequal: -> { described_class.new(role: :user, content: text("bye")) },
                     non_member: -> { described_class.new(role: :user, content: text("hi")).digest }
  end
end
