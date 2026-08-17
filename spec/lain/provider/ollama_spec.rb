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
    it "declares :streaming, :thinking, and :structured_output, and nothing it cannot demonstrate" do
      provider = described_class.new(transport: transport_sync({}))
      expect(provider.capabilities).to eq(%i[streaming thinking structured_output])
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

      expect(profile).to be_deeply_frozen
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

    # A CONNECTION-level failure, which is a different arm from a non-2xx and
    # was the one that leaked. Exhausted retries re-raise the last transport
    # failure as a bare `Faraday::Error` subclass -- it never passes through the
    # vendored ErrorMiddleware, so `rescue Provider::HTTP::Error` does not see
    # it and nothing above the Provider rescues a transport class either.
    #
    # It matters here more than anywhere: ollama is the DEFAULT summarizer
    # provider, so "ollama is not running" is the ordinary case, and since T9
    # the span summarizer answers on the RENDER path rather than behind
    # {Oracle::Eager}'s task boundary. Uncontained, it takes out the whole turn:
    # {Compaction::Strategy::Summarizing} rescues {Lain::Error} on purpose (a
    # NoMethodError from inside a tier is a defect to surface, not an outage to
    # absorb), so the containment has to be established HERE, exactly as
    # {Provider::Anthropic#complete} already establishes it.
    it "wraps an exhausted connection failure into APIError, not a bare Faraday class" do
      stub_request(:post, "http://localhost:11434/api/chat").to_raise(Faraday::ConnectionFailed)

      expect { described_class.new(config: zero_retry_config).complete(request(stream: false)) }
        .to raise_error(Lain::Provider::Ollama::APIError)
    end

    it "contains a streaming connection failure in the same family" do
      stub_request(:post, "http://localhost:11434/api/chat").to_raise(Faraday::ConnectionFailed)

      expect { described_class.new(config: zero_retry_config).complete(request(stream: true)) }
        .to raise_error(Lain::Error)
    end
  end

  # T9. The TRAINED window and the SERVED window are different numbers, and
  # only the served one is a denominator anything may divide by. `/api/show`
  # reports the trained maximum out of the GGUF metadata (262,144 for
  # qwen3-coder:30b); the served figure is min(trained, OLLAMA_CONTEXT_LENGTH,
  # per-request num_ctx), and `/api/ps`'s `context_length` -- the number
  # `ollama ps`'s CONTEXT column prints -- is the only place the API states it.
  # See references/ollama/api-show-and-context.md for the full trace.
  describe "#context_window_tokens" do
    # 32,768 is what this box actually serves (DEBUGGING_OLLAMA.md:43,
    # `OLLAMA_CONTEXT_LENGTH=32768`); 262,144 is qwen3-coder:30b's trained
    # ceiling. Any answer of 262,144 is an 8x over-estimate of occupancy,
    # which silently disables compaction.
    let(:served) { 32_768 }
    let(:trained) { 262_144 }

    def ps_entry(model, context_length: served)
      entry = { "name" => model, "model" => model, "size" => 18_000_000_000,
                "digest" => "abc123", "expires_at" => "2026-08-17T12:00:00Z", "size_vram" => 18_000_000_000 }
      context_length.nil? ? entry : entry.merge("context_length" => context_length)
    end

    def show_body(architecture: "qwen3moe", context_length: trained)
      { "model_info" => { "general.architecture" => architecture,
                          "#{architecture}.context_length" => context_length },
        "capabilities" => %w[completion tools] }
    end

    # Answers /api/ps only, and blows up loudly if an implementation reaches
    # for the trained number instead -- there is no #show here to call.
    def transport_ps(*entries)
      transport_body({ "models" => entries })
    end

    def transport_body(body)
      Class.new do
        define_method(:process_status) { Struct.new(:body).new(body) }
      end.new
    end

    it "answers the server's cap, never the trained ceiling above it" do
      provider = described_class.new(transport: transport_ps(ps_entry("qwen3-coder:30b")))

      expect(provider.context_window_tokens("qwen3-coder:30b")).to eq(served)
    end

    it "picks the entry for the model asked about, not the first one loaded" do
      transport = transport_ps(ps_entry("qwen3:4b", context_length: 4_096),
                               ps_entry("qwen3-coder:30b"))

      expect(described_class.new(transport:).context_window_tokens("qwen3-coder:30b")).to eq(served)
    end

    # An untagged model name resolves to :latest, which is how /api/ps prints it.
    it "resolves an untagged model against the :latest entry ollama reports" do
      provider = described_class.new(transport: transport_ps(ps_entry("qwen3:latest", context_length: 8_192)))

      expect(provider.context_window_tokens("qwen3")).to eq(8_192)
    end

    # The load-bearing refusal: a model that is not loaded has no served cap
    # yet, and the trained number is NOT a substitute for it.
    it "answers nil when the model is not loaded, rather than guessing" do
      expect(described_class.new(transport: transport_ps).context_window_tokens("qwen3-coder:30b")).to be_nil
    end

    it "answers nil when a server too old to report context_length omits the field" do
      transport = transport_ps(ps_entry("qwen3-coder:30b", context_length: nil))

      expect(described_class.new(transport:).context_window_tokens("qwen3-coder:30b")).to be_nil
    end

    it "answers nil on a zero, which is ollama's absent-integer, not a window" do
      transport = transport_ps(ps_entry("qwen3-coder:30b", context_length: 0))

      expect(described_class.new(transport:).context_window_tokens("qwen3-coder:30b")).to be_nil
    end

    it "answers nil on a body with no models key at all" do
      expect(described_class.new(transport: transport_body(nil)).context_window_tokens("qwen3-coder:30b")).to be_nil
    end

    # `/api/ps` prints both `name` and `model` from the same `displayName`
    # (`routes.go`'s ps handler), so they cannot legitimately disagree. Where
    # they do, the body is not ollama's, and matching on the second key would
    # hand back ANOTHER model's window -- the forbidden direction, arriving
    # from the field that carries no extra information.
    it "matches on model alone, so a disagreeing name cannot lend its window to another model" do
      transport = transport_ps({ "name" => "qwen3-coder:30b", "model" => "tinyllama:1b",
                                 "context_length" => served })

      expect(described_class.new(transport:).context_window_tokens("qwen3-coder:30b")).to be_nil
    end

    # A denominator lookup answers on the RENDER path. Every unknown is nil --
    # including a body that is not shaped like ollama's, which is reachable
    # whenever `api_base:` points at a proxy or at the wrong service entirely.
    # Four of these raised TypeError/NoMethodError straight through
    # `rescue APIError` before the fix.
    describe "on a body that is not ollama's" do
      {
        "a models object instead of an array" => { "models" => { "qwen3-coder:30b" => 32_768 } },
        "a bare integer where a runner belongs" => { "models" => [42] },
        "a pair array where a runner belongs" => { "models" => [%w[a b]] },
        "a null where a runner belongs" => { "models" => [nil] },
        "a string body" => "not json at all",
        "an array body" => [],
        "models as a string" => { "models" => "qwen3-coder:30b" }
      }.each do |shape, body|
        it "answers nil rather than raising on #{shape}" do
          provider = described_class.new(transport: transport_body(body))

          expect(provider.context_window_tokens("qwen3-coder:30b")).to be_nil
        end
      end

      it "still finds a well-formed runner sitting behind a junk entry" do
        transport = transport_ps(nil, 42, ps_entry("qwen3-coder:30b"))

        expect(described_class.new(transport:).context_window_tokens("qwen3-coder:30b")).to eq(served)
      end
    end

    # Upstream declares `ContextLength int` (`api/types.go`), so anything that
    # is not already an Integer is a body this code does not understand. Ruby's
    # Integer() would happily REINTERPRET several of these -- "0x40000" as hex
    # is 262,144, the exact 8x over-estimate this card exists to prevent -- so
    # the check is `is_a?`, not a coercion.
    describe "on a context_length that is not an Integer" do
      {
        "a hex string, which Integer() would read as 262144" => "0x40000",
        "an underscored string" => "262_144",
        "a padded decimal string" => " 32768 ",
        "a plain decimal string" => "32768",
        "a float" => 32_768.9,
        "a null" => nil,
        "an array" => [32_768]
      }.each do |shape, context_length|
        it "answers nil rather than coercing #{shape}" do
          transport = transport_ps(ps_entry("qwen3-coder:30b").merge("context_length" => context_length))

          expect(described_class.new(transport:).context_window_tokens("qwen3-coder:30b")).to be_nil
        end
      end
    end

    describe "over the real transport", :webmock do
      # AC 1, and the discriminating form of it: BOTH endpoints answer, and the
      # trained number is the one sitting there waiting to be picked up by
      # mistake. An implementation reading model_info returns 262,144 here.
      it "answers the served cap while /api/show is loudly offering the trained one" do
        stub_request(:get, "http://localhost:11434/api/ps")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: JSON.generate("models" => [ps_entry("qwen3-coder:30b")]))
        stub_request(:post, "http://localhost:11434/api/show")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: JSON.generate(show_body))

        expect(described_class.new.context_window_tokens("qwen3-coder:30b")).to eq(served)
      end

      # The card's whole safety property, pinned MECHANICALLY. An unused
      # WebMock stub fails nothing, so "we stubbed 262,144 and got 32,768" is
      # circumstantial: it holds for an implementation that reads /api/show and
      # then discards it, and it would keep holding if the stub silently
      # stopped matching. Asserting the request was never MADE is the property.
      it "never asks /api/show at all, so the trained number cannot reach the caller" do
        stub_request(:get, "http://localhost:11434/api/ps")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: JSON.generate("models" => [ps_entry("qwen3-coder:30b")]))
        show = stub_request(:post, "http://localhost:11434/api/show")
               .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate(show_body))

        described_class.new.context_window_tokens("qwen3-coder:30b")

        expect(show).not_to have_been_requested
        expect(a_request(:post, "http://localhost:11434/api/show")).not_to have_been_made
      end

      # AC 2. The trained length is discoverable; the CAP is not, because
      # nothing is loaded. nil, so ContextWindow's conservative fallback stands.
      it "answers nil when only the trained length is discoverable" do
        stub_request(:get, "http://localhost:11434/api/ps")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: JSON.generate("models" => []))
        stub_request(:post, "http://localhost:11434/api/show")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: JSON.generate(show_body))

        expect(described_class.new.context_window_tokens("qwen3-coder:30b")).to be_nil
      end

      # AC 3, and note the config: the SHIPPED one, not zero_retry_config. A
      # failure path measured with the retries turned off is not the failure
      # path anyone runs, and this arm's ordinary state is "ollama is not
      # running" -- so the budget is part of the behaviour under test.
      it "answers nil rather than raising when the server is not running" do
        stub_request(:get, "http://localhost:11434/api/ps").to_raise(Faraday::ConnectionFailed)

        expect(described_class.new.context_window_tokens("qwen3-coder:30b")).to be_nil
      end

      it "answers nil rather than raising on a non-2xx" do
        stub_request(:get, "http://localhost:11434/api/ps")
          .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                     body: JSON.generate("error" => "server error"))

        expect(described_class.new.context_window_tokens("qwen3-coder:30b")).to be_nil
      end

      it "answers nil rather than raising on a 404 from a server with no /api/ps" do
        stub_request(:get, "http://localhost:11434/api/ps")
          .to_return(status: 404, headers: { "Content-Type" => "application/json" }, body: "{}")

        expect(described_class.new.context_window_tokens("qwen3-coder:30b")).to be_nil
      end

      it "answers nil rather than raising when the probe times out" do
        stub_request(:get, "http://localhost:11434/api/ps").to_timeout

        expect(described_class.new.context_window_tokens("qwen3-coder:30b")).to be_nil
      end

      # A metadata probe must not inherit the COMPLETION path's retry budget.
      # `ServerError` and `ConnectionFailed` are both in MiddlewareStack's
      # retry_exceptions, so under the shipped config each of these costs three
      # attempts plus backoff -- ~760ms of dead wall time before a denominator
      # lookup on the render path gives up. One attempt is the whole answer.
      describe "the probe's own budget" do
        it "makes exactly one attempt when the server is down, not the completion path's three" do
          stub_request(:get, "http://localhost:11434/api/ps").to_raise(Faraday::ConnectionFailed)

          described_class.new.context_window_tokens("qwen3-coder:30b")

          expect(a_request(:get, "http://localhost:11434/api/ps")).to have_been_made.once
        end

        it "makes exactly one attempt when the server is up but 500s" do
          stub_request(:get, "http://localhost:11434/api/ps")
            .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                       body: JSON.generate("error" => "server error"))

          described_class.new.context_window_tokens("qwen3-coder:30b")

          expect(a_request(:get, "http://localhost:11434/api/ps")).to have_been_made.once
        end

        it "bounds the probe well under the completion path's 300s request_timeout" do
          transport = Lain::Provider::Ollama::Transport.new(Lain::Provider::HTTP::Configuration.new)

          expect(transport.probe_connection.connection.options.timeout)
            .to eq(Lain::Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS)
          expect(Lain::Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS).to be < 10
        end

        # The guard the budget change must not break: /api/chat keeps the
        # vendored three attempts, because a completion is worth waiting for.
        it "leaves the completion path's retry budget untouched" do
          stub_request(:post, "http://localhost:11434/api/chat")
            .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                       body: JSON.generate("error" => "boom"))

          expect { described_class.new(config: zero_retry_config).complete(request(stream: false)) }
            .to raise_error(Lain::Provider::Ollama::APIStatusError)
          expect(a_request(:post, "http://localhost:11434/api/chat")).to have_been_made.times(4)
        end
      end
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
