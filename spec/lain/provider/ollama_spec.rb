# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Provider::Ollama do
  # Non-streaming by default so these decode-focused examples exercise the sync
  # body path; the streaming path has its own spec (ollama_streaming_spec).
  def request(**overrides)
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64, stream: false,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  # A transport double returning a scripted body, for decode-focused examples.
  def transport_sync(body)
    Class.new do
      define_method(:sync_post) { |_payload, _headers = {}| Struct.new(:body).new(body) }
    end.new
  end

  def tool_call_body(*calls, done_reason: "stop", content: "")
    tool_calls = calls.map { |name, arguments| { "function" => { "name" => name, "arguments" => arguments } } }
    { "model" => "qwen3:4b",
      "message" => { "role" => "assistant", "content" => content, "tool_calls" => tool_calls },
      "done" => true, "done_reason" => done_reason,
      "prompt_eval_count" => 11, "eval_count" => 7 }
  end

  describe "#capabilities" do
    # :streaming is honest now that the NDJSON path exists (T17); :thinking is
    # honest now that `think` rides Request#extra onto the wire and the decode
    # path (already built) turns message.thinking into a thinking block (R5).
    # The remaining capabilities stay off deliberately -- declaring one the
    # native path cannot demonstrate would be a lying capability in the
    # subsystem built to catch them.
    it "declares :streaming and :thinking, and nothing it cannot demonstrate" do
      provider = described_class.new(transport: transport_sync({}))
      expect(provider.capabilities).to eq(%i[streaming thinking])
      expect(provider.capabilities - Lain::Provider::CAPABILITIES).to be_empty
    end
  end

  # CAC-2: :prompt_caching is honestly absent from CAPABILITIES above, so
  # #cache_profile reports a Null Object no-caching profile rather than nil --
  # a CAC-3/CAC-4 caller reads `ttl`/`tiered_invalidation` the same way
  # regardless of which provider it holds, no `if provider.supports?(...)`
  # guard needed first.
  describe "#cache_profile" do
    it "reports a no-caching profile, honest with :prompt_caching's absence from CAPABILITIES" do
      provider = described_class.new(transport: transport_sync({}))

      expect(provider.cache_profile).to eq(
        ttl: 0, min_prefix_tokens: Float::INFINITY, write_multiplier: 1.0, read_multiplier: 1.0,
        tiered_invalidation: false
      )
    end

    it "is a frozen, Ractor-shareable value" do
      provider = described_class.new(transport: transport_sync({}))

      profile = provider.cache_profile

      expect(profile).to be_frozen
      expect(Ractor.shareable?(profile)).to be(true)
    end
  end

  # AC 1: a tool-call round trip normalizes to the Lain contract.
  describe "#complete on a tool-call turn" do
    it "yields a tool_use block with Hash input, a synthesized id, and :tool_use despite done_reason stop" do
      provider = described_class.new(transport: transport_sync(tool_call_body(["echo", { "text" => "hi" }])))

      response = provider.complete(request)

      expect(response).to stop_with(:tool_use)
      expect(response.tool_uses.size).to eq(1)
      tool_use = response.tool_uses.first
      expect(tool_use["input"]).to eq({ "text" => "hi" })
      expect(tool_use["input"]).to be_a(Hash)
      expect(tool_use["name"]).to eq("echo")
      expect(tool_use["id"]).to be_a(String)
      expect(tool_use["id"]).not_to be_empty
    end

    it "synthesizes a stable, per-response-unique id for each parallel call" do
      provider = described_class.new(
        transport: transport_sync(tool_call_body(["echo", { "text" => "a" }], ["echo", { "text" => "b" }]))
      )

      ids = provider.complete(request).tool_uses.map { |block| block["id"] }

      expect(ids).to eq(ids.uniq)
      expect(ids.size).to eq(2)
    end

    it "honors a wire-provided id when present rather than synthesizing over it" do
      body = { "model" => "qwen3:4b",
               "message" => { "role" => "assistant", "content" => "",
                              "tool_calls" => [{ "id" => "call_7", "function" => { "name" => "echo",
                                                                                   "arguments" => {} } }] },
               "done" => true, "done_reason" => "stop" }

      response = described_class.new(transport: transport_sync(body)).complete(request)

      expect(response.tool_uses.first["id"]).to eq("call_7")
    end
  end

  # AC 2: cache markers never reach the wire, and encode is pure.
  describe "#encode" do
    let(:cached_request) do
      Lain::Request.new(
        model: "qwen3:4b", max_tokens: 64,
        system: [{ type: "text", text: "be terse", "cache" => true }],
        tools: [{ name: "echo", description: "echoes", "cache" => true,
                  input_schema: { type: "object", properties: {}, required: [] } }],
        messages: [{ role: "user", content: [{ type: "text", text: "hi", "cache" => true }] }]
      )
    end

    it "never leaks a cache marker onto the wire" do
      json = JSON.generate(described_class.new(transport: transport_sync({})).encode(cached_request))
      expect(json).not_to include("cache")
    end

    it "is pure -- the same Request twice yields byte-identical bytes" do
      provider = described_class.new(transport: transport_sync({}))
      first = provider.encode(cached_request)
      second = provider.encode(cached_request)
      expect(Lain::Canonical.dump(first)).to eq(Lain::Canonical.dump(second))
    end

    it "translates the Anthropic-shaped tool schema into Ollama's function form" do
      encoded = described_class.new(transport: transport_sync({})).encode(cached_request)

      expect(encoded[:tools]).to eq(
        [{ type: "function",
           function: { name: "echo", description: "echoes",
                       parameters: { "type" => "object", "properties" => {}, "required" => [] } } }]
      )
    end

    it "maps system to a leading system message" do
      encoded = described_class.new(transport: transport_sync({})).encode(cached_request)
      expect(encoded[:messages].first).to eq({ role: "system", content: "be terse" })
    end

    it "reads temperature, seed, and num_ctx from Request#extra into options" do
      req = request(extra: { temperature: 0, seed: 42, num_ctx: 8192 })
      encoded = described_class.new(transport: transport_sync({})).encode(req)
      expect(encoded[:options]).to eq({ temperature: 0, seed: 42, num_ctx: 8192 })
    end

    it "omits options entirely when no sampler knobs are given" do
      encoded = described_class.new(transport: transport_sync({})).encode(request)
      expect(encoded).not_to have_key(:options)
    end

    # AC: think round-trips. `think` is a top-level wire field (a sibling of
    # `stream`/`tools`), NOT part of `options` -- Ollama's own schema keeps it
    # out of the sampler knobs (references/ollama/api-chat.md).
    it "carries think onto its own top-level field, not into options" do
      encoded = described_class.new(transport: transport_sync({})).encode(request(extra: { think: true }))
      expect(encoded[:think]).to be(true)
      expect(encoded[:options]).to be_nil
    end

    # AC: non-think runs unchanged. No think extra means no `think` key at
    # all -- today's wire bytes are untouched.
    it "omits think entirely when no think extra is given" do
      encoded = described_class.new(transport: transport_sync({})).encode(request)
      expect(encoded).not_to have_key(:think)
    end
  end

  # AC: think round-trips, end to end -- the request body carries think and the
  # decoded Response carries a thinking block shaped the same way the Anthropic
  # path shapes one ({"type" => "thinking", "thinking" => ...}; Ollama has no
  # signature to carry, so that key is simply absent rather than nil-padded).
  describe "#complete with think enabled" do
    it "sends think:true and decodes a thinking block matching the Anthropic shape" do
      canned = Lain::Response.new(
        content: [{ "type" => "thinking", "thinking" => "reasoning trace" },
                  { "type" => "text", "text" => "42" }],
        stop_reason: :end_turn
      )
      transport = OllamaWire.queue_transport(canned)
      provider = described_class.new(transport:)

      response = provider.complete(request(extra: { think: true }))

      expect(transport.calls.first[:think]).to be(true)
      expect(response.blocks_of_type("thinking")).to eq([{ "type" => "thinking", "thinking" => "reasoning trace" }])
      expect(response.text).to eq("42")
    end
  end

  # The sync path echoes request.stream onto the wire (Ollama's wire default is
  # true, so the flag is always sent explicitly); complete routes to sync_post.
  describe "#complete on the non-streaming path" do
    it "sends stream: false and routes to the sync transport" do
      provider = described_class.new(transport: (recorder = capturing_transport))
      provider.complete(request(stream: false))
      expect(recorder.payload[:stream]).to be(false)
    end

    it "returns a text Response from a non-streaming body" do
      body = { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "hello" },
               "done" => true, "done_reason" => "stop", "prompt_eval_count" => 3, "eval_count" => 2 }
      response = described_class.new(transport: transport_sync(body)).complete(request(stream: false))

      expect(response.text).to eq("hello")
      expect(response).to stop_with(:end_turn)
      expect(response.usage.input_tokens).to eq(3)
      expect(response.usage.output_tokens).to eq(2)
    end
  end

  describe "done_reason -> stop_reason" do
    it "maps length to :max_tokens" do
      body = { "message" => { "role" => "assistant", "content" => "x" }, "done_reason" => "length" }
      expect(described_class.new(transport: transport_sync(body)).complete(request)).to stop_with(:max_tokens)
    end

    it "maps the empty-string (connection-closed) reason to :unknown" do
      body = { "message" => { "role" => "assistant", "content" => "" }, "done_reason" => "" }
      expect(described_class.new(transport: transport_sync(body)).complete(request)).to stop_with(:unknown)
    end
  end

  # The real Faraday transport, exercised once end-to-end over WebMock so the URL,
  # path, and JSON (de)serialization are pinned, not just the injected double.
  describe "over the real transport", :webmock do
    it "posts stream:false to /api/chat at the default base and parses the body" do
      stub = stub_request(:post, "http://localhost:11434/api/chat")
             .with { |r| JSON.parse(r.body)["stream"] == false }
             .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate("model" => "qwen3:4b",
                                            "message" => { "role" => "assistant", "content" => "pong" },
                                            "done" => true, "done_reason" => "stop"))

      response = described_class.new.complete(request(stream: false))

      expect(response.text).to eq("pong")
      expect(stub).to have_been_requested
    end

    # The sync error arm: a non-2xx body raises through the vendored
    # ErrorMiddleware and is wrapped by wrap_error, so nothing above the
    # Provider rescues a Provider::HTTP class -- status lifted onto the error.
    # The zeroed config keeps faraday-retry's loop in play without its sleeps,
    # and the config's retry_block seam proves the retries actually fired
    # before the error surfaced.
    it "wraps a 500 into APIStatusError with the status lifted out, after exhausting retries" do
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("error" => "model runner has unexpectedly stopped"))

      config = zero_retry_config
      retries = []
      config.retry_block = ->(retry_count:, **) { retries << retry_count }

      expect { described_class.new(config:).complete(request(stream: false)) }.to raise_error(
        Lain::Provider::Ollama::APIStatusError
      ) { |error| expect(error.status).to eq(500) }
      expect(retries).to eq([0, 1, 2])
    end
  end

  # A transport double that captures the payload it was handed.
  def capturing_transport
    Class.new do
      attr_reader :payload

      def sync_post(payload, _headers = {})
        @payload = payload
        Struct.new(:body).new({ "message" => { "role" => "assistant", "content" => "ok" }, "done_reason" => "stop" })
      end
    end.new
  end
end
