# frozen_string_literal: true

RSpec.describe Lain::Context::MessageEnvelope do
  def block(type, text) = { "type" => type, "text" => text }

  def message(role, *blocks) = { "role" => role, "content" => blocks }

  describe ".wrap" do
    it "adopts a bare hash" do
      hash = message("user", block("text", "hi"))
      expect(described_class.wrap(hash)).to be_a(described_class)
    end

    it "is idempotent: wrapping an envelope returns that same envelope" do
      envelope = described_class.wrap(message("user", block("text", "hi")))
      expect(described_class.wrap(envelope)).to be(envelope)
    end
  end

  describe "#to_h" do
    it "returns the ORIGINAL hash by identity, never a copy" do
      hash = message("user", block("text", "hi"))
      expect(described_class.wrap(hash).to_h).to be(hash)
    end

    it "returns the original hash through a double wrap too" do
      hash = message("user", block("text", "hi"))
      expect(described_class.wrap(described_class.wrap(hash)).to_h).to be(hash)
    end
  end

  describe "#user?" do
    it "is true for a user message" do
      expect(described_class.wrap(message("user")).user?).to be(true)
    end

    it "is false for any other role" do
      expect(described_class.wrap(message("assistant")).user?).to be(false)
    end
  end

  describe "#real_text_blocks" do
    it "keeps text blocks" do
      envelope = described_class.wrap(message("user", block("text", "a"), block("text", "b")))
      expect(envelope.real_text_blocks.map { |b| b["text"] }).to eq(%w[a b])
    end

    it "drops non-text blocks" do
      envelope = described_class.wrap(
        message("user", block("text", "a"), { "type" => "tool_result", "content" => "x" })
      )
      expect(envelope.real_text_blocks.map { |b| b["text"] }).to eq(%w[a])
    end

    it "drops <workspace>-tagged text blocks" do
      envelope = described_class.wrap(
        message("user", block("text", "a"), block("text", "#{Lain::Workspace::OPENING_TAG}todo</workspace>"))
      )
      expect(envelope.real_text_blocks.map { |b| b["text"] }).to eq(%w[a])
    end
  end

  describe "#query_text" do
    it "joins the real text blocks with newlines" do
      envelope = described_class.wrap(message("user", block("text", "a"), block("text", "b")))
      expect(envelope.query_text).to eq("a\nb")
    end

    it "is nil when there is no real text (e.g. a tool-result tail)" do
      envelope = described_class.wrap(message("user", { "type" => "tool_result", "content" => "x" }))
      expect(envelope.query_text).to be_nil
    end
  end

  describe "#workspace_tagged?" do
    it "is true for a block whose text leads with the opening tag" do
      envelope = described_class.wrap(message("user"))
      expect(envelope.workspace_tagged?(block("text", "#{Lain::Workspace::OPENING_TAG}x</workspace>"))).to be(true)
    end

    it "is false for ordinary text" do
      envelope = described_class.wrap(message("user"))
      expect(envelope.workspace_tagged?(block("text", "ordinary"))).to be(false)
    end
  end

  describe "the read-only contract" do
    let(:envelope) { described_class.wrap(message("user", block("text", "hi"))) }

    it "is frozen" do
      expect(envelope).to be_frozen
    end

    it "exposes no mutating method" do
      %i[[]= << push merge merge! store delete].each do |mutator|
        expect(envelope).not_to respond_to(mutator)
      end
    end
  end
end
