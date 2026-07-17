# frozen_string_literal: true

require "json"

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
    expect(request).to be_deeply_frozen
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
      expect(a).to have_same_digest_as(b)
    end

    it "changes when the prompt changes" do
      a = request
      b = request(messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "bye" }] }])
      expect(a).not_to have_same_digest_as(b)
    end

    it "changes when tools change, since tools lead the cached prefix" do
      tool = { "name" => "read_file", "description" => "reads", "input_schema" => { "type" => "object" } }
      expect(request).not_to have_same_digest_as(request(tools: [tool]))
    end

    # Toggling streaming must not read as a different prompt, or every
    # stream/non-stream switch would look like a cache break.
    it "ignores transport concerns" do
      expect(request(stream: true)).to have_same_digest_as(request(stream: false))
    end

    it "ignores extra, which is transport too" do
      expect(request).to have_same_digest_as(request(extra: { "trace_id" => "abc" }))
    end

    # The purity constraint and the cache-hit constraint are the same constraint.
    it "is unchanged by rebuilding an identical request" do
      expect(request).to have_same_digest_as(request)
    end
  end

  describe "#cache_prefix" do
    it "is tools then system, the order Anthropic matches on" do
      req = request(system: "be terse")
      expect(req.cache_prefix.keys).to eq(%w[tools system])
    end
  end

  # to_s is the human-facing projection; inspect keeps the class-tagged,
  # debug-oriented form -- the DegradedSet convention (see
  # capability/degraded_set_spec.rb).
  describe "string conversions" do
    subject(:req) { request }

    it "renders to_s as the human projection, untagged" do
      expect(req.to_s).to eq("#{req.model} msgs=#{req.messages.size} tools=#{req.tools.size} #{req.digest[0, 19]}...")
    end

    it "keeps inspect class-tagged for debugging" do
      expect(req.inspect).to eq("#<Lain::Request #{req}>")
    end

    it "does not alias to_s and inspect" do
      expect(req.method(:to_s)).not_to eq(req.method(:inspect))
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
      messages = texts.zip(caches).map { |text, cache| marked_message(text, cache:) }
      described_class.new(model: "claude-opus-4-8", system:, messages:, max_tokens: 1024)
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
      a = chained_request(texts:, caches: [false, true, false, true])
      b = chained_request(texts:, caches: [false, false, true, true])

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

    # R.1: the chain is a ROLLING hash -- each entry H(previous entry,
    # marker-stripped message), seeded by the fixed prefix -- so journaling
    # cost is linear in messages, where format 1 re-digested the full
    # stripped prefix per marker (O(turns^2) per session).
    describe "rolling chain (format 2)" do
      it "names its format: PREFIX_CHAIN_VERSION is 2" do
        expect(Lain::Request::PREFIX_CHAIN_VERSION).to eq(2)
      end

      it "chains each entry as H(previous entry, marker-stripped message), seeded by the fixed prefix" do
        req = chained_request(system_cache: true, texts: %w[m0 m1], caches: [true, true])

        seed = Lain::Canonical.digest(
          "model" => req.model, "tools" => [], "system" => [{ "type" => "text", "text" => "sys" }]
        )
        entry0 = Lain::Canonical.digest(
          [seed, { "role" => "user", "content" => [{ "type" => "text", "text" => "m0" }] }]
        )
        entry1 = Lain::Canonical.digest(
          [entry0, { "role" => "user", "content" => [{ "type" => "text", "text" => "m1" }] }]
        )
        expect(req.prefix_digests).to eq([[-1, seed], [0, entry0], [1, entry1]])
      end

      # The linearity claim, observed at the primitive: N messages under N
      # markers cost N + 1 digest calls (one seed, one per message), and no
      # call ever digests a multi-message prefix -- the O(N^2) shape format 1
      # had is structurally impossible, not merely avoided.
      it "invokes the digest primitive once per message plus one seed, never over a multi-message prefix" do
        req = chained_request(texts: Array.new(8) { |i| "m#{i}" }, caches: [true] * 8)

        digested = []
        allow(Lain::Canonical).to receive(:digest).and_wrap_original do |original, value|
          digested << value
          original.call(value)
        end
        req.prefix_digests

        expect(digested.size).to eq(9)
        full_prefix_payloads = digested.select { |value| value.is_a?(Hash) && value.key?("messages") }
        expect(full_prefix_payloads).to be_empty
      end
    end
  end

  describe "#cache_payload" do
    # Canonical BY CONSTRUCTION -- sorted String keys, deeply frozen, values
    # normalized at Request.new -- so the journaling path can carry it without
    # a second deep normalize pass (R.3): Canonical.normalize of this Hash is
    # a structural no-op.
    # Pinned by BYTES, not Hash#==: equality is insertion-order-blind, so
    # `normalize(payload) eq payload` could never catch a key-order drift.
    # JSON.generate preserves insertion order and Canonical.dump sorts
    # recursively -- byte equality IS the canonical-by-construction contract,
    # at every nesting depth.
    it "is already canonical wire form: byte-identical to its own canonical dump, and deeply frozen" do
      payload = request(system: "be terse").cache_payload

      expect(JSON.generate(payload)).to eq(Lain::Canonical.dump(payload))
      expect(payload).to be_deeply_frozen
    end
  end

  # R.1's version marker and R.3's one-pass normalization are properties of
  # the JOURNALING seam (Middleware::JournalRequests -> Telemetry::RequestSent),
  # pinned here because both exist to serve Request's chain contract.
  describe "journaling: a versioned chain, one normalize pass (R.1/R.3)" do
    let(:journal) { RecordingChannel.new }

    def journaled(req)
      Lain::Middleware::JournalRequests.new(journal:).call({ request: req }) { |env| env }
      journal.events.first
    end

    def marked_request
      request(system: [{ "type" => "text", "text" => "sys", "cache" => true }])
    end

    it "names the chain format version on the record, so an offline reader can refuse cross-format comparison" do
      event = journaled(marked_request)

      expect(event.prefix_chain_version).to eq(Lain::Request::PREFIX_CHAIN_VERSION)
      expect(event.to_journal.fetch("prefix_chain_version")).to eq(Lain::Request::PREFIX_CHAIN_VERSION)
    end

    it "normalizes the payload once -- the digest's own pass -- not twice" do
      req = marked_request
      payload = req.cache_payload
      allow(Lain::Canonical).to receive(:normalize).and_call_original

      journaled(req)

      expect(Lain::Canonical).to have_received(:normalize).with(payload).once
    end

    it "structurally shares the request's members rather than re-copying the message history" do
      req = marked_request
      event = journaled(req)

      expect(event.payload["messages"]).to equal(req.messages)
      expect(event.payload["system"]).to equal(req.system)
    end

    it "stays deeply frozen and Ractor-shareable on the fast path" do
      event = journaled(marked_request)

      expect(event).to be_deeply_frozen
      expect(event).to be_ractor_shareable
    end
  end
end
