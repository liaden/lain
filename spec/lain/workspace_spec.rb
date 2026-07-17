# frozen_string_literal: true

RSpec.describe Lain::Workspace do
  describe ".empty" do
    it "is a shared, frozen, Ractor-shareable value with no reminders" do
      first = described_class.empty
      second = described_class.empty

      expect(first).to be(second)
      expect(first).to be(described_class::EMPTY)
      expect(first).to be_deeply_frozen
      expect(first.reminders).to be_empty
      expect(first).to be_empty
    end
  end

  describe "#initialize" do
    it "freezes via the Freezable concern, deeply and Ractor-shareably" do
      workspace = described_class.new(reminders: %w[a b])

      expect(workspace).to be_deeply_frozen
    end

    it "holds its reminders in order, deeply frozen" do
      expect(described_class.new(reminders: %w[a b]).reminders).to eq(%w[a b])
    end
  end

  describe "#empty?" do
    it "delegates to reminders" do
      expect(described_class.new).to be_empty
      expect(described_class.new(reminders: %w[x])).not_to be_empty
    end
  end

  describe "#with" do
    it "returns self when nothing is added, sparing the steady-state allocation" do
      workspace = described_class.new(reminders: %w[a])
      expect(workspace.with).to be(workspace)
    end

    it "returns a new frozen Workspace with the reminders appended in order" do
      workspace = described_class.new(reminders: %w[a]).with("b", "c")

      expect(workspace.reminders).to eq(%w[a b c])
      expect(workspace).to be_deeply_frozen
    end
  end

  describe "#to_blocks" do
    it "wraps each reminder in the workspace tags and the structural provenance marker" do
      expect(described_class.new(reminders: %w[hi]).to_blocks)
        .to eq([{ "type" => "text", "text" => "<workspace>hi</workspace>", described_class::WORKSPACE_MARKER => true }])
    end
  end

  # R.2: structural provenance (WORKSPACE_MARKER) replaces the OPENING_TAG
  # text-prefix match MessageEnvelope#workspace_tagged? used to key off. The
  # marker itself must never leak past two boundaries: onto the wire (mirrors
  # AnthropicEncoding::CACHE_MARKER, which is stripped the same way) and into
  # a Request's prefix-digest chain (mirrors Request#strip_cache_markers).
  describe "structural provenance never crosses a wire or digest boundary" do
    def request_with(block)
      Lain::Request.new(model: "m", max_tokens: 64, messages: [{ "role" => "user", "content" => [block] }])
    end

    # No Hash anywhere in the encoded payload may carry the workspace key,
    # whatever type it lands on the wire under (String key for Anthropic,
    # Symbol key for Ollama's Symbol-keyed payload shape).
    def refute_workspace_key(value)
      case value
      when Hash
        expect(value.keys.map(&:to_s)).not_to include(described_class::WORKSPACE_MARKER)
        value.each_value { |v| refute_workspace_key(v) }
      when Array
        value.each { |v| refute_workspace_key(v) }
      end
    end

    let(:workspace_block) { described_class.new(reminders: ["todo"]).to_blocks.first }

    it "never puts the marker on an Anthropic-encoded payload" do
      encoder = Class.new do
        include Lain::Provider::AnthropicEncoding

        def supports?(_capability) = false
      end.new

      refute_workspace_key(encoder.encode(request_with(workspace_block)))
    end

    it "never puts the marker on an Ollama-encoded payload" do
      encoder = Class.new { include Lain::Provider::Ollama::Encoding }.new

      refute_workspace_key(encoder.encode(request_with(workspace_block)))
    end

    # Scenario: prefix digests strip it like cache -- a marker-bearing block
    # and its already-stripped twin must roll to the SAME prefix-digest chain,
    # exactly the invariant Request#strip_cache_markers gives "cache".
    it "computes identical prefix_digests whether or not the block still carries the marker" do
      tagged = workspace_block.merge("cache" => true)
      already_stripped = tagged.except(described_class::WORKSPACE_MARKER)

      expect(request_with(tagged).prefix_digests).to eq(request_with(already_stripped).prefix_digests)
    end
  end
end
