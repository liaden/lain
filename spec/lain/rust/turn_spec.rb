# frozen_string_literal: true

require "lain"

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
      expect(turn.content).to be_frozen
      expect(turn.content.first).to be_frozen
      expect(turn.content.first["text"]).to be_frozen
    end

    it "freezes the turn itself" do
      expect(described_class.new(role: :user, content: text("hi"))).to be_frozen
    end

    # The whole reason the port is allowed: a magnus TypedData wrapping only
    # immutable Rust state stays Ractor-shareable once frozen.
    it "is Ractor-shareable" do
      turn = described_class.new(role: :user, content: text("hi"), meta: { "a" => 1 })
      expect(Ractor.shareable?(turn)).to be(true)
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
      expect(base.digest).not_to eq(described_class.new(role: :assistant, content: text("hi")).digest)
      expect(base.digest).not_to eq(described_class.new(role: :user, content: text("bye")).digest)
      expect(base.digest).not_to eq(described_class.new(role: :user, content: text("hi"), parent: "blake3:abc").digest)
      expect(base.digest).not_to eq(described_class.new(role: :user, content: text("hi"), meta: { "s" => "x" }).digest)
    end

    # The port is only correct if its content address equals the Ruby Turn's to
    # the byte, over the same inputs -- including parent and meta.
    it "equals the Ruby Turn digest byte-for-byte" do
      ext = described_class.new(role: :user, content: text("hi"),
                                parent: "blake3:abc", meta: { "spawned_from" => "blake3:xyz" })
      ruby = Lain::Turn.new(role: :user, content: text("hi"),
                            parent: "blake3:abc", meta: { "spawned_from" => "blake3:xyz" })
      expect(ext.digest).to eq(ruby.digest)
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
