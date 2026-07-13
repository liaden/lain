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
      define_method(:stream) { |_payload, _headers = {}, &blk| events.each(&blk) }
    end.new
  end

  def transport_sync(body)
    Class.new do
      define_method(:sync_post) { |_payload, _headers = {}| Struct.new(:body).new(body) }
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

      expect(response.stop_reason).to eq(Lain::StopReason::UNKNOWN)
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
      expect(response.stop_reason).to eq(:tool_use)
    end
  end

  describe "#complete error wrapping" do
    def transport_raising(error)
      Class.new do
        define_method(:stream) { |_payload, _headers = {}, &_blk| raise error }
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
      provider = described_class.new(channel: channel, api_key: "test")

      provider.complete(request(stream: false))

      retries = channel.events.grep(Lain::Event::ProviderRetry)
      expect(retries.size).to eq(1)
      expect(retries.first.will_retry_in).to eq(2.0)
      expect(retries.first.status).to eq(429)
      expect(retries.first.attempt).to eq(1)
    end
  end
end
