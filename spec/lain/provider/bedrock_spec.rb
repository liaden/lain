# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Provider::Bedrock do
  # A response content block, faked at the shape the SDK actually returns:
  # `.type` is a Symbol, and a streamed tool_use's `.input` is a raw String.
  def block(**attrs)
    Struct.new(*attrs.keys, keyword_init: true).new(**attrs)
  end

  def text_block(text) = block(type: :text, text:)

  def tool_use_block(input:, id: "toolu_1", name: "read_file")
    block(type: :tool_use, id:, name:, input:)
  end

  def usage_double(input: 10, output: 5)
    block(input_tokens: input, output_tokens: output,
          cache_creation_input_tokens: nil, cache_read_input_tokens: nil)
  end

  def message_double(content:, stop_reason: :end_turn)
    block(id: "msg_1", model: "anthropic.claude-opus-4-8", content:, stop_reason:, usage: usage_double)
  end

  # A doubled Mantle client: a single-pass stream whose `accumulated_message`
  # yields the message. Injected so no unit test touches the network.
  def client_returning(message)
    stream = instance_double("Anthropic::Streaming::MessageStream", accumulated_message: message)
    messages = instance_double("Anthropic::Resources::Messages", stream:)
    instance_double("Anthropic::BedrockMantleClient", messages:)
  end

  subject(:provider) { described_class.new(client:) }

  let(:client) { client_returning(message_double(content: [text_block("hi")])) }

  describe "provider contract subset" do
    it "claims exactly the Bedrock feature mask, as its own literal list" do
      expect(provider.capabilities).to eq(%i[streaming prompt_caching strict_tools thinking parallel_tool_use])
    end

    it "owns its CAPABILITIES constant rather than aliasing another provider's" do
      expect(described_class::CAPABILITIES).not_to be(Lain::Provider::Anthropic::CAPABILITIES)
    end

    it "encodes deterministically across Hashes built with keys in opposite order" do
      one = Lain::Request.new(model: "m", max_tokens: 1,
                              tools: [{ name: "t", description: "d",
                                        input_schema: { type: :object, properties: {}, required: [] } }],
                              messages: [{ role: "user", content: [{ type: "text", text: "x" }] }])
      two = Lain::Request.new(max_tokens: 1, model: "m",
                              messages: [{ content: [{ text: "x", type: "text" }], role: "user" }],
                              tools: [{ input_schema: { required: [], properties: {}, type: :object },
                                        description: "d", name: "t" }])

      expect(JSON.generate(provider.encode(one))).to eq(JSON.generate(provider.encode(two)))
    end

    it "defaults to the anthropic.-prefixed Bedrock model id" do
      expect(described_class::DEFAULT_MODEL).to eq("anthropic.claude-opus-4-8")
    end
  end

  describe "default client" do
    it "is an Anthropic::BedrockMantleClient, constructed in bearer mode without aws-sdk-core complaints" do
      provider = nil
      expect { provider = described_class.new(api_key: "tok", aws_region: "us-east-1") }.not_to raise_error
      expect(provider.instance_variable_get(:@client)).to be_a(Anthropic::BedrockMantleClient)
    end
  end

  # The one test that exercises the real SDK end-to-end over a stubbed socket:
  # it proves the derived Mantle URL, the bearer Authorization header, the model
  # riding in the JSON body, and that a streamed tool_use `input` genuinely
  # arrives as a JSON String from the accumulator before we parse it.
  describe "over the wire (webmock)" do
    let(:endpoint) { "https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages" }

    let(:sse) do
      <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"anthropic.claude-opus-4-8","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1,"cache_creation_input_tokens":null,"cache_read_input_tokens":null}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"let me look"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\": \\"lib/x.rb\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":15}}

        event: message_stop
        data: {"type":"message_stop"}
      SSE
    end

    let(:request) do
      Lain::Request.new(
        model: "anthropic.claude-opus-4-8", max_tokens: 10, stream: true,
        tools: [{ name: "read_file", description: "read",
                  input_schema: { type: "object", properties: {}, required: [] } }],
        messages: [{ role: "user", content: "hi" }]
      )
    end

    it "POSTs to the derived Mantle endpoint with bearer auth and keeps every block, inputs parsed" do
      stub_request(:post, endpoint)
        .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })

      provider = described_class.new(api_key: "tok", aws_region: "us-east-1")
      response = provider.complete(request)

      expect(a_request(:post, endpoint).with(headers: { "Authorization" => "Bearer tok" }) do |req|
        expect(JSON.parse(req.body)).to include("model" => "anthropic.claude-opus-4-8")
      end).to have_been_made
      expect(response.content.map { |b| b["type"] }).to eq(%w[text tool_use])
      expect(response.tool_uses.first["input"]).to eq("path" => "lib/x.rb")
      expect(response).to stop_with(:tool_use)
    end
  end

  describe "errors and prices" do
    let(:request) { Lain::Request.new(model: "m", max_tokens: 1, messages: [{ role: "user", content: "hi" }]) }

    it "wraps an SDK APIStatusError in its own, preserving the Integer status and the cause" do
      sdk_error = Anthropic::Errors::RateLimitError.new(
        url: URI("https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages"), status: 429,
        headers: nil, body: nil, request: nil, response: nil, message: "slow down"
      )
      messages = instance_double("Anthropic::Resources::Messages")
      allow(messages).to receive(:stream).and_raise(sdk_error)
      provider = described_class.new(client: instance_double("Anthropic::BedrockMantleClient", messages:))

      expect { provider.complete(request) }.to raise_error(Lain::Provider::Bedrock::APIStatusError) do |wrapped|
        expect(wrapped.status).to eq(429)
        expect(wrapped.cause).to be(sdk_error)
        expect(wrapped).to be_a(Lain::Error)
      end
    end

    it "resolves the anthropic.-prefixed model id to the opus price row" do
      expect(Lain::PriceBook::DEFAULT.price("anthropic.claude-opus-4-8"))
        .to eq(Lain::PriceBook::DEFAULTS.fetch("opus"))
    end
  end
end
