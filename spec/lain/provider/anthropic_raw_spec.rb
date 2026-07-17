# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Provider::AnthropicRaw do
  def request(**overrides)
    Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  # A transport double that yields a scripted list of raw SSE events (streaming)
  # or returns a scripted body (sync).
  def transport_streaming(events)
    Class.new do
      define_method(:stream) { |_payload, _headers = {}, **, &blk| events.each(&blk) }
    end.new
  end

  def transport_sync(body)
    Class.new do
      define_method(:sync_post) { |_payload, _headers = {}, **| Struct.new(:body).new(body) }
    end.new
  end

  describe "#capabilities" do
    it "claims exactly what it can demonstrate, and only known capabilities" do
      provider = described_class.new(transport: transport_sync({}))
      expect(provider.capabilities).to eq(%i[streaming prompt_caching strict_tools thinking parallel_tool_use])
      expect(Lain::Provider::CAPABILITIES).to include(*provider.capabilities)
    end
  end

  # The headline verification: the forked encode is byte-identical to the SDK
  # oracle's over cache markers + tools + strict + a system prompt. VCR cannot
  # prove this (cassettes match on method+URI, not body).
  describe "#encode differential against the SDK oracle" do
    let(:oracle) { Lain::Provider::Anthropic.new(client: Object.new) }
    let(:forked) { described_class.new(transport: transport_sync({})) }

    let(:rich_request) do
      Lain::Request.new(
        model: "claude-opus-4-8", max_tokens: 1024,
        system: [{ type: "text", text: "be terse", "cache" => true }],
        tools: [{ name: "read_file", description: "read", strict: true,
                  input_schema: { type: "object", properties: {}, required: [] } }],
        messages: [{ role: "user", content: [{ type: "text", text: "hi", "cache" => true }] }],
        extra: { temperature: 0.2 }
      )
    end

    it "produces the same kwargs the SDK provider would send" do
      expect(forked.encode(rich_request)).to eq(oracle.encode(rich_request))
    end

    it "keeps the SDK's trailing-underscore system_ keyword" do
      expect(forked.encode(rich_request)).to have_key(:system_)
      expect(forked.encode(rich_request)).not_to have_key(:system)
    end
  end

  # T17w fix round: Backend now hands live chat traffic to this transport
  # under --journal, where it used to be the SDK client -- so its effective
  # request envelope must match the SDK's, not the vendored HTTP stack's own
  # (ruby_llm-derived) generic defaults, or --journal silently trades away
  # timeout/retry budget nobody asked to trade.
  describe "the default request envelope" do
    it "mirrors the SDK's own timeout and retry budget, not HTTP::Configuration's generic defaults" do
      config = described_class.new(api_key: "sk-test").instance_variable_get(:@config)

      # Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS (600.0) / DEFAULT_MAX_RETRIES (2) --
      # HTTP::Configuration's own option defaults are 300 / 3, vendored from ruby_llm.
      expect(config.request_timeout).to eq(600)
      expect(config.max_retries).to eq(2)
    end
  end

  describe "#complete over the streaming path" do
    it "retains the full ordered block list -- thinking, text, tool_use -- with every signature" do
      canned = Lain::Response.new(
        stop_reason: :tool_use,
        content: [{ "type" => "thinking", "thinking" => "a", "signature" => "sig-A" },
                  { "type" => "thinking", "thinking" => "b", "signature" => "sig-B" },
                  { "type" => "text", "text" => "looking" },
                  { "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => { "path" => "x.rb" } }]
      )
      provider = described_class.new(transport: transport_streaming(AnthropicSSE.events(canned)))

      response = provider.complete(request)

      expect(response.content.map { |block| block["type"] }).to eq(%w[thinking thinking text tool_use])
      expect(response.blocks_of_type("thinking").map { |block| block["signature"] }).to eq(%w[sig-A sig-B])
    end

    it "parses a streamed tool_use input into a Hash so nothing above sees a String" do
      canned = Lain::Response.new(stop_reason: :tool_use,
                                  content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "grep",
                                              "input" => { "pattern" => "foo" } }])
      provider = described_class.new(transport: transport_streaming(AnthropicSSE.events(canned)))

      input = provider.complete(request).tool_uses.first["input"]
      expect(input).to eq("pattern" => "foo")
      expect(input).to be_a(Hash)
    end

    it "maps usage including nil cache fields to zero" do
      events = [
        { "type" => "message_start",
          "message" => { "id" => "m", "model" => "claude-opus-4-8",
                         "usage" => { "input_tokens" => 100, "output_tokens" => 1,
                                      "cache_creation_input_tokens" => nil, "cache_read_input_tokens" => nil } } },
        { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" }, "usage" => { "output_tokens" => 20 } }
      ]
      usage = described_class.new(transport: transport_streaming(events)).complete(request).usage

      expect(usage.input_tokens).to eq(100)
      expect(usage.output_tokens).to eq(20)
      expect(usage.cache_creation_input_tokens).to eq(0)
      expect(usage.cache_read_input_tokens).to eq(0)
    end

    it "normalizes an unrecognized stop_reason to :unknown rather than raising" do
      events = [{ "type" => "message_start", "message" => { "id" => "m" } },
                { "type" => "message_delta", "delta" => { "stop_reason" => "some_2027_reason" }, "usage" => {} }]
      response = described_class.new(transport: transport_streaming(events)).complete(request)

      expect(response).to stop_with(Lain::StopReason::UNKNOWN)
    end
  end

  # CE-5: the transient first-token scheduling signal (cache-economics.md).
  describe "#complete CE-5 stream_started" do
    let(:channel) { RecordingChannel.new }
    let(:canned) { Lain::Response.new(stop_reason: :end_turn, content: [{ "type" => "text", "text" => "hi" }]) }

    it "emits exactly one stream_started on the Channel, attributed with the request digest, " \
       "before any content_block event reaches the assembler" do
      events = AnthropicSSE.events(canned)
      recorded_events = channel.events # a true local, so the closure below sees it regardless of `self`
      signaled_before_content_block = nil
      transport = Class.new do
        define_method(:stream) do |_payload, _headers = {}, **, &blk|
          events.each do |event|
            if event["type"] == "content_block_start" && signaled_before_content_block.nil?
              signaled_before_content_block = recorded_events.any?(Lain::Telemetry::StreamStarted)
            end
            blk.call(event)
          end
        end
      end.new
      req = request
      provider = described_class.new(transport:, channel:)

      provider.complete(req)

      started = channel.events.grep(Lain::Telemetry::StreamStarted)
      expect(started.size).to eq(1)
      expect(started.first.digest).to eq(req.digest)
      expect(signaled_before_content_block).to be(true)
    end

    it "hands the digest to a per-request observer without touching the Channel" do
      transport = transport_streaming(AnthropicSSE.events(canned))
      provider = described_class.new(transport:, channel:)
      req = request
      observed = []

      provider.complete(req, on_stream_started: ->(digest) { observed << digest })

      expect(observed).to eq([req.digest])
      expect(channel.events.grep(Lain::Telemetry::StreamStarted).size).to eq(1)
    end

    # Review fix: a bad orchestration policy must not cost #complete its
    # response. The observer call sits outside the response path entirely --
    # only its own failure is isolated, and it must be surfaced, not
    # swallowed (see Lain::Telemetry::ObserverFailed).
    it "still returns the response and still emits stream_started when the observer raises, " \
       "surfacing the failure instead of swallowing it" do
      transport = transport_streaming(AnthropicSSE.events(canned))
      provider = described_class.new(transport:, channel:)
      req = request
      raising = ->(_digest) { raise "boom from orchestration policy" }

      response = provider.complete(req, on_stream_started: raising)

      expect(response.content).to eq(canned.content)
      started = channel.events.grep(Lain::Telemetry::StreamStarted)
      expect(started.size).to eq(1)
      expect(started.first.digest).to eq(req.digest)
      failures = channel.events.grep(Lain::Telemetry::ObserverFailed)
      expect(failures.size).to eq(1)
      expect(failures.first.hook).to eq(:stream_started)
      expect(failures.first.digest).to eq(req.digest)
      expect(failures.first.message).to eq("boom from orchestration policy")
    end

    it "emits nothing at all on the non-streaming path" do
      transport = transport_sync({ "id" => "m", "model" => "m", "stop_reason" => "end_turn",
                                   "content" => [{ "type" => "text", "text" => "hi" }], "usage" => {} })
      provider = described_class.new(transport:, channel:)
      observed = []

      provider.complete(request(stream: false), on_stream_started: ->(digest) { observed << digest })

      expect(channel.events.grep(Lain::Telemetry::StreamStarted)).to be_empty
      expect(observed).to be_empty
    end
  end

  describe "#complete over the non-streaming path" do
    it "maps a create-shaped body into a Response, tool inputs already parsed" do
      body = { "id" => "msg_1", "model" => "claude-opus-4-8", "stop_reason" => "tool_use",
               "content" => [{ "type" => "text", "text" => "hi" },
                             { "type" => "tool_use", "id" => "tu_1", "name" => "t", "input" => { "k" => "v" } }],
               "usage" => { "input_tokens" => 5, "output_tokens" => 2 } }
      provider = described_class.new(transport: transport_sync(body))

      response = provider.complete(request(stream: false))

      expect(response.content.map { |block| block["type"] }).to eq(%w[text tool_use])
      expect(response.tool_uses.first["input"]).to eq("k" => "v")
      expect(response).to stop_with(:tool_use)
    end
  end

  describe "#complete error wrapping" do
    def transport_raising(error)
      Class.new do
        define_method(:stream) { |_payload, _headers = {}, **, &_blk| raise error }
      end.new
    end

    it "wraps a status-bearing transport error as APIStatusError under Lain::Error" do
      response = Struct.new(:status).new(429)
      sdk_error = Lain::Provider::HTTP::RateLimitError.new(response, "slow down")
      provider = described_class.new(transport: transport_raising(sdk_error))

      expect { provider.complete(request) }.to raise_error(described_class::APIStatusError) do |wrapped|
        expect(wrapped.status).to eq(429)
        expect(wrapped).to be_a(Lain::Error)
        expect(wrapped.cause).to be(sdk_error)
      end
    end

    it "wraps a transport error with no response as APIError" do
      sdk_error = Lain::Provider::HTTP::Error.new("boom")
      provider = described_class.new(transport: transport_raising(sdk_error))

      expect { provider.complete(request) }.to raise_error(described_class::APIError) do |wrapped|
        expect(wrapped).not_to be_a(described_class::APIStatusError)
        expect(wrapped.cause).to be(sdk_error)
      end
    end
  end

  # Step C, end to end through the REAL vendored Faraday stack + faraday-retry:
  # a 429 carrying a reset header must journal exactly ONE retry event and back
  # off by the header's value. A silent retry hides real spend.
  describe "retry journaling over the real transport" do
    let(:channel) { RecordingChannel.new }

    let(:success_body) do
      JSON.generate("id" => "msg_1", "model" => "claude-opus-4-8", "stop_reason" => "end_turn",
                    "content" => [{ "type" => "text", "text" => "ok" }],
                    "usage" => { "input_tokens" => 1, "output_tokens" => 1 })
    end

    let(:error_body) do
      JSON.generate("type" => "error", "error" => { "type" => "rate_limit_error", "message" => "x" })
    end

    before do
      # No real time lost to backoff; we assert the value it WOULD have slept.
      allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep)
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 429, body: error_body,
                   headers: { "anthropic-ratelimit-tokens-reset" => "2", "Content-Type" => "application/json" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: success_body)
    end

    it "journals one ProviderRetry that backs off by the reset header's value" do
      provider = described_class.new(channel:, api_key: "test")

      provider.complete(request(stream: false))

      retries = channel.events.grep(Lain::Telemetry::ProviderRetry)
      expect(retries.size).to eq(1)
      expect(retries.first.will_retry_in).to eq(2.0)
      expect(retries.first.status).to eq(429)
      expect(retries.first.attempt).to eq(1)
    end
  end

  # RES1: a streamed error must be classified by the REAL HTTP status --
  # already known from the response headers, before any body byte streams in
  # (see FaradayHandlers#v2_on_data) -- exactly as the sync path is. Left
  # unfixed, `parse_streaming_error`'s body-shape guess (500, or 529 for
  # "overloaded_error") wins over that known status, so a genuine 400 read as
  # ServerError -- which IS in the retry allowlist -- and faraday-retry
  # retried a request the sync path never would. Real transport + webmock,
  # like the sync retry-journaling group above, because the bug lives in how
  # Faraday's on_data/retry/error-middleware interplay resolves the status,
  # not in anything a transport test double can observe.
  describe "streamed error classification matches the sync path (RES1)" do
    let(:channel) { RecordingChannel.new }

    let(:success_sse) do
      AnthropicSSE.body(Lain::Response.new(stop_reason: :end_turn, content: [{ "type" => "text", "text" => "ok" }]))
    end

    before do
      allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep)
    end

    it "raises the sync path's error class for a streamed 400, with no retry" do
      error_body = JSON.generate("type" => "error",
                                 "error" => { "type" => "invalid_request_error", "message" => "bad request" })
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 400, body: error_body, headers: { "Content-Type" => "application/json" })
      provider = described_class.new(channel:, api_key: "test")

      expect { provider.complete(request) }.to raise_error(described_class::APIStatusError) do |wrapped|
        expect(wrapped.status).to eq(400)
        expect(wrapped.cause).to be_a(Lain::Provider::HTTP::BadRequestError)
      end
      expect(channel.events.grep(Lain::Telemetry::ProviderRetry)).to be_empty
    end

    it "retries a streamed 429 under exactly the sync path's classification" do
      error_body = JSON.generate("type" => "error", "error" => { "type" => "rate_limit_error", "message" => "x" })
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 429, body: error_body,
                   headers: { "anthropic-ratelimit-tokens-reset" => "2", "Content-Type" => "application/json" })
        .to_return(status: 200, body: success_sse, headers: { "Content-Type" => "text/event-stream" })
      provider = described_class.new(channel:, api_key: "test")

      response = provider.complete(request)

      expect(response.content).to eq([{ "text" => "ok", "type" => "text" }])
      retries = channel.events.grep(Lain::Telemetry::ProviderRetry)
      expect(retries.size).to eq(1)
      expect(retries.first.status).to eq(429)
      expect(retries.first.reason).to eq("Lain::Provider::HTTP::RateLimitError")
    end

    it "retries a streamed 5xx under exactly the sync path's classification" do
      error_body = JSON.generate("type" => "error", "error" => { "type" => "overloaded_error", "message" => "busy" })
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 529, body: error_body, headers: { "Content-Type" => "application/json" })
        .to_return(status: 200, body: success_sse, headers: { "Content-Type" => "text/event-stream" })
      provider = described_class.new(channel:, api_key: "test")

      response = provider.complete(request)

      expect(response.content).to eq([{ "text" => "ok", "type" => "text" }])
      retries = channel.events.grep(Lain::Telemetry::ProviderRetry)
      expect(retries.size).to eq(1)
      expect(retries.first.status).to eq(529)
      expect(retries.first.reason).to eq("Lain::Provider::HTTP::OverloadedError")
    end
  end
end
