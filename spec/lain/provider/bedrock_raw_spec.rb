# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Provider::BedrockRaw do
  def request(**overrides)
    Lain::Request.new(model: "anthropic.claude-opus-4-8", max_tokens: 64,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  # A transport double that only needs to exist so no real Transport/Connection
  # is built; the config is still constructed by #build_config.
  def null_transport
    Class.new do
      define_method(:sync_post) { |_payload, _headers = {}| Struct.new(:body).new({}) }
    end.new
  end

  describe "the wire payload" do
    let(:rich_request) do
      Lain::Request.new(
        model: "anthropic.claude-opus-4-8", max_tokens: 1024, stream: true,
        system: [{ type: "text", text: "be terse", "cache" => true }],
        tools: [{ name: "read_file", description: "read", strict: true,
                  input_schema: { type: "object", properties: {}, required: [] } }],
        messages: [{ role: "user", content: [{ type: "text", text: "hi", "cache" => true }] }]
      )
    end

    it "keeps model in the body, rewrites system_ to system, and sets stream" do
      provider = described_class.new(transport: null_transport)
      payload = provider.send(:wire_payload, rich_request)

      expect(payload[:model]).to eq("anthropic.claude-opus-4-8")
      expect(payload).to have_key(:system)
      expect(payload).not_to have_key(:system_)
      expect(payload[:stream]).to be(true)
    end
  end

  describe "DEFAULT_MODEL and encode parity with the oracle" do
    let(:shared_request) do
      Lain::Request.new(
        model: "anthropic.claude-opus-4-8", max_tokens: 512,
        system: [{ type: "text", text: "be terse", "cache" => true }],
        tools: [{ name: "read_file", description: "read", strict: true,
                  input_schema: { type: "object", properties: {}, required: [] } }],
        messages: [{ role: "user", content: [{ type: "text", text: "hi", "cache" => true }] }],
        extra: { temperature: 0.2 }
      )
    end

    it "defaults to the anthropic.-prefixed Bedrock model id" do
      expect(described_class::DEFAULT_MODEL).to eq("anthropic.claude-opus-4-8")
    end

    it "encodes byte-identically to the Provider::Bedrock SDK oracle" do
      forked = described_class.new(transport: null_transport)
      oracle = Lain::Provider::Bedrock.new(client: Object.new)

      expect(forked.encode(shared_request)).to eq(oracle.encode(shared_request))
    end
  end

  describe "#build_config env fallbacks at the provider layer" do
    it "reads bedrock_api_key and bedrock_region from AWS_BEARER_TOKEN_BEDROCK and AWS_REGION" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("AWS_BEARER_TOKEN_BEDROCK", nil).and_return("env-token")
      allow(ENV).to receive(:fetch).with("AWS_REGION", nil).and_return("us-west-2")

      provider = described_class.new(transport: null_transport)
      config = provider.instance_variable_get(:@config)

      expect(config.bedrock_api_key).to eq("env-token")
      expect(config.bedrock_region).to eq("us-west-2")
    end

    it "prefers explicit kwargs over the environment" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("AWS_BEARER_TOKEN_BEDROCK", nil).and_return("env-token")
      allow(ENV).to receive(:fetch).with("AWS_REGION", nil).and_return("us-west-2")

      provider = described_class.new(transport: null_transport, api_key: "explicit", region: "eu-central-1")
      config = provider.instance_variable_get(:@config)

      expect(config.bedrock_api_key).to eq("explicit")
      expect(config.bedrock_region).to eq("eu-central-1")
    end
  end

  # The real Connection reaches the Mantle endpoint intact: the /anthropic path
  # suffix of the derived base URL must survive Faraday's URL join (the named
  # join trap), and bearer auth must ride, never x-api-key.
  describe "the real Connection reaches the Mantle endpoint (webmock, offline)" do
    let(:endpoint) { "https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages" }

    let(:sse) do
      AnthropicSSE.body(Lain::Response.new(id: "msg_1", model: "anthropic.claude-opus-4-8",
                                           stop_reason: :end_turn,
                                           content: [{ "type" => "text", "text" => "ok" }]))
    end

    it "POSTs to the derived Mantle endpoint with bearer auth and no x-api-key" do
      stub_request(:post, endpoint)
        .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })

      provider = described_class.new(api_key: "tok", region: "us-east-1")
      provider.complete(request(stream: true))

      expect(a_request(:post, endpoint).with(headers: { "Authorization" => "Bearer tok" }))
        .to have_been_made
      expect(a_request(:post, endpoint).with { |req| req.headers.key?("X-Api-Key") })
        .not_to have_been_made
    end
  end

  # Step C, end to end through the REAL vendored Faraday stack + faraday-retry:
  # a 429 carrying a reset header must journal exactly ONE retry event. A silent
  # retry hides real spend.
  describe "retry journaling over the real transport" do
    let(:channel) { RecordingChannel.new }
    let(:endpoint) { "https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages" }

    let(:success_body) do
      JSON.generate("id" => "msg_1", "model" => "anthropic.claude-opus-4-8", "stop_reason" => "end_turn",
                    "content" => [{ "type" => "text", "text" => "ok" }],
                    "usage" => { "input_tokens" => 1, "output_tokens" => 1 })
    end

    let(:error_body) do
      JSON.generate("type" => "error", "error" => { "type" => "rate_limit_error", "message" => "x" })
    end

    before do
      allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep)
      stub_request(:post, endpoint)
        .to_return(status: 429, body: error_body,
                   headers: { "anthropic-ratelimit-tokens-reset" => "2", "Content-Type" => "application/json" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: success_body)
    end

    it "journals exactly one ProviderRetry" do
      provider = described_class.new(channel:, api_key: "tok", region: "us-east-1")

      provider.complete(request(stream: false))

      retries = channel.events.grep(Lain::Telemetry::ProviderRetry)
      expect(retries.size).to eq(1)
      expect(retries.first.status).to eq(429)
      expect(retries.first.attempt).to eq(1)
    end
  end
end
