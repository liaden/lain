# frozen_string_literal: true

RSpec.describe Lain::Turn do
  def text(body) = [{ "type" => "text", "text" => body }]

  describe "construction" do
    it "accepts the two wire roles" do
      expect(Lain::Turn::ROLES).to contain_exactly("user", "assistant")
    end

    it "rejects any other role" do
      expect { described_class.new(role: "system", content: text("x")) }
        .to raise_error(Lain::Turn::InvalidRole, /must be one of/)
    end

    it "accepts a Symbol role" do
      expect(described_class.new(role: :user, content: text("x")).role).to eq("user")
    end

    it "is a root when it has no parent" do
      expect(described_class.new(role: :user, content: text("x"))).to be_root
    end
  end

  describe "content" do
    # What is hashed and what is retained must not drift apart, so the Turn keeps
    # the normalized wire form rather than whatever the caller happened to pass.
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
  end

  describe "#digest" do
    it "is a prefixed content address" do
      expect(described_class.new(role: :user, content: text("hi")).digest).to start_with("sha256:")
    end

    it "is identical for identical content" do
      a = described_class.new(role: :user, content: text("hi"))
      b = described_class.new(role: :user, content: text("hi"))
      expect(a.digest).to eq(b.digest)
    end

    it "changes with content" do
      a = described_class.new(role: :user, content: text("hi"))
      b = described_class.new(role: :user, content: text("bye"))
      expect(a.digest).not_to eq(b.digest)
    end

    it "changes with role" do
      a = described_class.new(role: :user, content: text("hi"))
      b = described_class.new(role: :assistant, content: text("hi"))
      expect(a.digest).not_to eq(b.digest)
    end

    it "changes with parent, which is what chains the DAG" do
      a = described_class.new(role: :user, content: text("hi"))
      b = described_class.new(role: :user, content: text("hi"), parent: "sha256:abc")
      expect(a.digest).not_to eq(b.digest)
    end

    # meta carries causal lineage (e.g. "spawned_from"), so it must be inside the
    # digest or two causally distinct turns would share an address.
    it "changes with meta" do
      a = described_class.new(role: :user, content: text("hi"))
      b = described_class.new(role: :user, content: text("hi"), meta: { "spawned_from" => "sha256:abc" })
      expect(a.digest).not_to eq(b.digest)
    end
  end

  describe "equality (Regular)" do
    let(:a) { described_class.new(role: :user, content: text("hi")) }
    let(:b) { described_class.new(role: :user, content: text("hi")) }
    let(:c) { described_class.new(role: :user, content: text("bye")) }

    it "is structural" do
      expect(a).to eq(b)
      expect(a).not_to eq(c)
    end

    it "is not equal to a non-Turn" do
      expect(a).not_to eq(a.digest)
    end

    # Object#hash must stay an Integer or Hash and Set bucketing silently breaks.
    it "returns an Integer from #hash" do
      expect(a.hash).to be_a(Integer)
    end

    it "works as a Hash key" do
      expect({ a => :found }[b]).to eq(:found)
    end

    it "deduplicates in a Set" do
      expect(Set[a, b, c].size).to eq(2)
    end
  end
end
