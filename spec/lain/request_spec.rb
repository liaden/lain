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

  describe "#prefix_digests" do
    def marked_message(text, cache:)
      block = { "type" => "text", "text" => text }
      block = block.merge("cache" => true) if cache
      { "role" => "user", "content" => [block] }
    end

    def chained_request(texts:, caches:, system_cache: false)
      system = system_cache ? [{ "type" => "text", "text" => "sys", "cache" => true }] : nil
      messages = texts.zip(caches).map { |text, cache| marked_message(text, cache: cache) }
      described_class.new(model: "claude-opus-4-8", system: system, messages: messages, max_tokens: 1024)
    end

    it "is empty when neither system nor messages carry a marker" do
      req = chained_request(texts: %w[a b], caches: [false, false])
      expect(req.prefix_digests).to eq([])
    end

    it "returns one (position, digest) pair per marker, in ascending position order" do
      req = chained_request(system_cache: true, texts: %w[m0 m1 m2 m3], caches: [false, true, false, true])

      chain = req.prefix_digests
      expect(chain.size).to eq(3) # system + message 1 + message 3
      expect(chain.map(&:first)).to eq([-1, 1, 3])
    end

    it "is deterministic: computing it twice yields the same pairs" do
      req = chained_request(system_cache: true, texts: %w[m0 m1], caches: [false, true])
      expect(req.prefix_digests).to eq(req.prefix_digests)
    end

    it "digests are marker-placement-independent: a shared position hashes the same regardless of marker placement" do
      texts = %w[m0 m1 m2 m3]
      a = chained_request(texts: texts, caches: [false, true, false, true])
      b = chained_request(texts: texts, caches: [false, false, true, true])

      a_chain = a.prefix_digests.to_h
      b_chain = b.prefix_digests.to_h
      expect(a_chain).to have_key(3)
      expect(b_chain).to have_key(3)
      expect(a_chain[3]).to eq(b_chain[3])
    end

    it "localizes divergence: chains agree at every shared position up to the split, and differ beyond it" do
      shared = %w[a0 a1 a2]
      a = chained_request(texts: shared + ["diverges-a"], caches: [true, true, true, true])
      b = chained_request(texts: shared + ["diverges-b"], caches: [true, true, true, true])

      a_chain = a.prefix_digests.to_h
      b_chain = b.prefix_digests.to_h
      expect(a_chain[0]).to eq(b_chain[0])
      expect(a_chain[1]).to eq(b_chain[1])
      expect(a_chain[2]).to eq(b_chain[2])
      expect(a_chain[3]).not_to eq(b_chain[3])
    end

    # The Recall/workspace-tail pattern: CacheBreakpoints marks the last block,
    # then a later stage appends an unmarked block after it. cache_control
    # covers bytes through the marked BLOCK, so this is a clean cut, not an
    # ambiguity -- and the digest must be blind to what was appended.
    it "handles a marker on a non-final block, and the digest ignores the unmarked trailing block" do
      marked_block = { "type" => "text", "text" => "a", "cache" => true }
      trailing = { "type" => "text", "text" => "<recall>hit</recall>" }
      with_trailing = described_class.new(
        model: "claude-opus-4-8",
        messages: [{ "role" => "user", "content" => [marked_block, trailing] }],
        max_tokens: 1024
      )
      without_trailing = described_class.new(
        model: "claude-opus-4-8",
        messages: [{ "role" => "user", "content" => [marked_block] }],
        max_tokens: 1024
      )

      chain = with_trailing.prefix_digests
      expect(chain.size).to eq(1)
      expect(chain.first.first).to eq(0)
      expect(chain.first.last).to eq(without_trailing.prefix_digests.first.last)
    end

    it "raises when a single message carries more than one marker, rather than guessing which cuts the prefix" do
      ambiguous = { "role" => "user", "content" => [
        { "type" => "text", "text" => "a", "cache" => true },
        { "type" => "text", "text" => "b", "cache" => true }
      ] }
      req = described_class.new(model: "claude-opus-4-8", messages: [ambiguous], max_tokens: 1024)

      expect { req.prefix_digests }.to raise_error(Lain::Request::AmbiguousMarkerPosition)
    end
  end
end
