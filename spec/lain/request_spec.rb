# frozen_string_literal: true

RSpec.describe Lain::Request do
  def request(**overrides)
    described_class.new(
      model: "claude-opus-4-8",
      messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }],
      max_tokens: 1024,
      **overrides
    )
  end

  it "is frozen" do
    expect(request).to be_frozen
  end

  it "normalizes messages into wire form" do
    req = request(messages: [{ role: :user, content: [{ type: :text, text: "hi" }] }])
    expect(req.messages).to eq([{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }])
  end

  it "defaults to streaming, because agentic max_tokens exceeds the non-streaming ceiling" do
    expect(request.stream).to be(true)
  end

  it "defaults to no tools and no system" do
    expect(request.tools).to eq([])
    expect(request.system).to be_nil
  end

  describe "#digest" do
    it "is stable across key insertion order" do
      a = request(extra: { "b" => 1, "a" => 2 })
      b = request(extra: { "a" => 2, "b" => 1 })
      expect(a.digest).to eq(b.digest)
    end

    it "changes when the prompt changes" do
      a = request
      b = request(messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "bye" }] }])
      expect(a.digest).not_to eq(b.digest)
    end

    it "changes when tools change, since tools lead the cached prefix" do
      tool = { "name" => "read_file", "description" => "reads", "input_schema" => { "type" => "object" } }
      expect(request.digest).not_to eq(request(tools: [tool]).digest)
    end

    # Toggling streaming must not read as a different prompt, or every
    # stream/non-stream switch would look like a cache break.
    it "ignores transport concerns" do
      expect(request(stream: true).digest).to eq(request(stream: false).digest)
    end

    it "ignores extra, which is transport too" do
      expect(request.digest).to eq(request(extra: { "trace_id" => "abc" }).digest)
    end

    # The purity constraint and the cache-hit constraint are the same constraint.
    it "is unchanged by rebuilding an identical request" do
      expect(request.digest).to eq(request.digest)
    end
  end

  describe "#cache_prefix" do
    it "is tools then system, the order Anthropic matches on" do
      req = request(system: "be terse")
      expect(req.cache_prefix.keys).to eq(%w[tools system])
    end
  end

  describe "cache breakpoints are provider-neutral" do
    # A block carries `"cache" => true`; rendering that as cache_control is the
    # Provider's job, and a provider that cannot must say so via #capabilities.
    it "carries a neutral cache marker through normalization" do
      req = request(system: [{ "type" => "text", "text" => "sys", "cache" => true }])
      expect(req.system.first["cache"]).to be(true)
    end
  end
end
