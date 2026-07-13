# frozen_string_literal: true

require "lain/provider/anthropic"
require "webmock/rspec"

RSpec.describe Lain::Provider::Anthropic do
  # A response content block, faked at the shape the SDK actually returns:
  # `.type` is a Symbol, and a streamed tool_use's `.input` is a raw String.
  def block(**attrs)
    Struct.new(*attrs.keys, keyword_init: true).new(**attrs)
  end

  def text_block(text) = block(type: :text, text: text)

  def thinking_block(thinking: "step", signature: "sig")
    block(type: :thinking, thinking: thinking, signature: signature)
  end

  def tool_use_block(input:, id: "toolu_1", name: "read_file")
    block(type: :tool_use, id: id, name: name, input: input)
  end

  def usage_double(input: 10, output: 5, cache_creation: nil, cache_read: nil)
    block(input_tokens: input, output_tokens: output,
          cache_creation_input_tokens: cache_creation, cache_read_input_tokens: cache_read)
  end

  def message_double(content:, stop_reason: :end_turn, id: "msg_1", model: "claude-opus-4-8", usage: usage_double)
    block(id: id, model: model, content: content, stop_reason: stop_reason, usage: usage)
  end

  # A doubled SDK client. `messages.create` returns the message directly;
  # `messages.stream` returns a single-pass stream whose `accumulated_message`
  # yields it. Injected so no unit test touches the network.
  def client_returning(message, via: :stream)
    messages = instance_double("Anthropic::Resources::Messages")
    if via == :stream
      stream = instance_double("Anthropic::Streaming::MessageStream", accumulated_message: message)
      allow(messages).to receive(:stream).and_return(stream)
    else
      allow(messages).to receive(:create).and_return(message)
    end
    instance_double("Anthropic::Client", messages: messages)
  end

  subject(:provider) { described_class.new(client: client) }

  let(:client) { client_returning(message_double(content: [text_block("hi")])) }

  describe "#capabilities" do
    it "claims exactly what it can demonstrate" do
      expect(provider.capabilities).to eq(%i[streaming prompt_caching strict_tools thinking parallel_tool_use])
    end

    it "declares only capabilities the base class knows about" do
      expect(Lain::Provider::CAPABILITIES).to include(*provider.capabilities)
    end
  end

  describe "#encode" do
    it "maps Request#system onto the SDK's trailing-underscore system_ keyword" do
      request = Lain::Request.new(model: "m", max_tokens: 1, system: "you are terse",
                                  messages: [{ role: "user", content: "hi" }])
      encoded = provider.encode(request)

      expect(encoded).to include(system_: "you are terse")
      expect(encoded).not_to have_key(:system)
    end

    it "is deterministic across Hashes built with keys in opposite order" do
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

    it "keeps strict tool schemas" do
      request = Lain::Request.new(model: "m", max_tokens: 1,
                                  tools: [{ name: "t", description: "d", strict: true,
                                            input_schema: { type: :object, properties: {}, required: [] } }],
                                  messages: [{ role: "user", content: "hi" }])

      expect(provider.encode(request)[:tools].first).to include("strict" => true)
    end

    it "translates a neutral cache marker into cache_control and strips the marker" do
      request = Lain::Request.new(
        model: "m", max_tokens: 1,
        system: [{ type: "text", text: "sys", "cache" => true }],
        messages: [{ role: "user", content: [{ type: "text", text: "hi", "cache" => true }] }]
      )
      encoded = provider.encode(request)

      sys = encoded[:system_].first
      msg = encoded[:messages].first["content"].first
      [sys, msg].each do |emitted|
        expect(emitted).to include("cache_control" => { "type" => "ephemeral" })
        expect(emitted).not_to have_key("cache")
      end
    end

    it "drops a falsy cache marker without emitting cache_control" do
      content = [{ type: "text", text: "hi", "cache" => false }]
      request = Lain::Request.new(model: "m", max_tokens: 1, messages: [{ role: "user", content: content }])
      emitted = provider.encode(request)[:messages].first["content"].first

      expect(emitted).not_to have_key("cache")
      expect(emitted).not_to have_key("cache_control")
    end

    # CE-1: placement (including the budget and the tail-clustered dropping
    # of old markers) is entirely Context::CacheBreakpoints's job now; the
    # encoder used to also place its own intermediate breakpoint every 15
    # blocks, uncapped, and the two layers together were how a long enough
    # session exceeded Anthropic's 4-marker cap. See
    # spec/lain/provider/anthropic_encoding_spec.rb for the encoder's own
    # coverage of this contract.
    it "places no breakpoint of its own -- only where a neutral marker already sits" do
      blocks = Array.new(32) { |i| { type: "text", text: "b#{i}" } }
      request = Lain::Request.new(model: "m", max_tokens: 1,
                                  messages: [{ role: "user", content: blocks }])
      emitted = provider.encode(request)[:messages].first["content"]

      expect(emitted.count { |block| block.key?("cache_control") }).to eq(0)
    end

    it "does not include a stream key (the SDK encodes streaming by method choice)" do
      request = Lain::Request.new(model: "m", max_tokens: 1, stream: true,
                                  messages: [{ role: "user", content: "hi" }])
      expect(provider.encode(request)).not_to have_key(:stream)
    end

    it "forwards provider-specific params from #extra as symbol keys" do
      request = Lain::Request.new(model: "m", max_tokens: 1, extra: { temperature: 0.2 },
                                  messages: [{ role: "user", content: "hi" }])
      expect(provider.encode(request)).to include(temperature: 0.2)
    end
  end

  describe "#complete content" do
    it "keeps the full block list -- text, thinking, and tool_use alike" do
      message = message_double(
        stop_reason: :tool_use,
        content: [thinking_block, text_block("let me look"), tool_use_block(input: '{"path":"x"}')]
      )
      response = described_class.new(client: client_returning(message)).complete(request)

      expect(response.content.map { |b| b["type"] }).to eq(%w[thinking text tool_use])
    end

    it "parses a streamed tool_use input that arrives as a JSON String into a Hash" do
      message = message_double(stop_reason: :tool_use,
                               content: [tool_use_block(input: '{"path":"lib/x.rb"}')])
      response = described_class.new(client: client_returning(message)).complete(request)

      input = response.tool_uses.first["input"]
      expect(input).to eq("path" => "lib/x.rb")
      expect(input).to be_a(Hash)
    end

    it "passes through a tool_use input that already arrived parsed (the create path)" do
      message = message_double(stop_reason: :tool_use,
                               content: [tool_use_block(input: { path: "lib/x.rb" })])
      response = described_class.new(client: client_returning(message)).complete(request)

      expect(response.tool_uses.first["input"]).to eq("path" => "lib/x.rb")
    end

    let(:request) do
      Lain::Request.new(model: "m", max_tokens: 1, messages: [{ role: "user", content: "hi" }])
    end
  end

  describe "#complete stop reasons" do
    let(:request) { Lain::Request.new(model: "m", max_tokens: 1, messages: [{ role: "user", content: "hi" }]) }

    Lain::StopReason::KNOWN.each do |reason|
      it "normalizes the #{reason} stop reason" do
        message = message_double(content: [text_block("x")], stop_reason: reason)
        response = described_class.new(client: client_returning(message)).complete(request)
        expect(response.stop_reason).to eq(reason)
      end
    end

    it "maps an unknown stop reason to :unknown rather than raising" do
      message = message_double(content: [text_block("x")], stop_reason: :some_new_beta_reason)
      response = described_class.new(client: client_returning(message)).complete(request)
      expect(response.stop_reason).to eq(Lain::StopReason::UNKNOWN)
    end

    it "maps a nil stop reason to :unknown" do
      message = message_double(content: [text_block("x")], stop_reason: nil)
      response = described_class.new(client: client_returning(message)).complete(request)
      expect(response.stop_reason).to eq(Lain::StopReason::UNKNOWN)
    end
  end

  describe "#complete usage" do
    let(:request) { Lain::Request.new(model: "m", max_tokens: 1, messages: [{ role: "user", content: "hi" }]) }

    it "maps all four token counters" do
      message = message_double(content: [text_block("x")],
                               usage: usage_double(input: 100, output: 20, cache_creation: 30, cache_read: 40))
      usage = described_class.new(client: client_returning(message)).complete(request).usage

      expect(usage.input_tokens).to eq(100)
      expect(usage.output_tokens).to eq(20)
      expect(usage.cache_creation_input_tokens).to eq(30)
      expect(usage.cache_read_input_tokens).to eq(40)
    end

    it "normalizes nil cache counters to zero" do
      message = message_double(content: [text_block("x")],
                               usage: usage_double(cache_creation: nil, cache_read: nil))
      usage = described_class.new(client: client_returning(message)).complete(request).usage

      expect(usage.cache_creation_input_tokens).to eq(0)
      expect(usage.cache_read_input_tokens).to eq(0)
    end
  end

  describe "#complete non-streaming path" do
    it "calls create, not stream, when the Request opts out of streaming" do
      message = message_double(content: [text_block("hi")])
      client = client_returning(message, via: :create)
      request = Lain::Request.new(model: "m", max_tokens: 1, stream: false,
                                  messages: [{ role: "user", content: "hi" }])

      response = described_class.new(client: client).complete(request)

      expect(response.text).to eq("hi")
      expect(client.messages).to have_received(:create)
    end
  end

  describe "#complete error wrapping" do
    let(:request) { Lain::Request.new(model: "m", max_tokens: 1, messages: [{ role: "user", content: "hi" }]) }

    def client_raising(error)
      messages = instance_double("Anthropic::Resources::Messages")
      allow(messages).to receive(:stream).and_raise(error)
      instance_double("Anthropic::Client", messages: messages)
    end

    it "wraps an APIStatusError, preserving the Integer status and the SDK error as cause" do
      sdk_error = Anthropic::Errors::RateLimitError.new(
        url: URI("https://api.anthropic.com/v1/messages"), status: 429, headers: nil,
        body: nil, request: nil, response: nil, message: "slow down"
      )
      provider = described_class.new(client: client_raising(sdk_error))

      expect { provider.complete(request) }.to raise_error(Lain::Provider::Anthropic::APIStatusError) do |wrapped|
        expect(wrapped.status).to eq(429)
        expect(wrapped.cause).to be(sdk_error)
        expect(wrapped).to be_a(Lain::Error)
      end
    end

    it "wraps a non-status SDK error as APIError, still under Lain::Error" do
      sdk_error = Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com/v1/messages"))
      provider = described_class.new(client: client_raising(sdk_error))

      expect { provider.complete(request) }.to raise_error(Lain::Provider::Anthropic::APIError) do |wrapped|
        expect(wrapped).not_to be_a(Lain::Provider::Anthropic::APIStatusError)
        expect(wrapped.cause).to be(sdk_error)
      end
    end
  end

  # The one test that exercises the real SDK end-to-end over a stubbed socket:
  # it proves the encoded body actually carries `system` (not `system_`) and
  # `cache_control`, and that a streamed tool_use `input` genuinely arrives as a
  # JSON String from the accumulator before we parse it.
  describe "over the wire (webmock)" do
    let(:sse) do
      <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-4-8","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1,"cache_creation_input_tokens":null,"cache_read_input_tokens":null}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\": \\"lib/x.rb\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":15}}

        event: message_stop
        data: {"type":"message_stop"}
      SSE
    end

    let(:request) do
      Lain::Request.new(
        model: "claude-opus-4-8", max_tokens: 10, stream: true,
        system: [{ type: "text", text: "sys", "cache" => true }],
        tools: [{ name: "read_file", description: "read",
                  input_schema: { type: "object", properties: {}, required: [] } }],
        messages: [{ role: "user", content: "hi" }]
      )
    end

    it "sends `system` and `cache_control` on the wire and parses the streamed String input" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })

      provider = described_class.new(client: Anthropic::Client.new(api_key: "test"))
      response = provider.complete(request)

      expect(a_request(:post, "https://api.anthropic.com/v1/messages").with do |req|
        captured = JSON.parse(req.body)
        expect(captured).to have_key("system")
        expect(captured).not_to have_key("system_")
        expect(captured.dig("system", 0, "cache_control")).to eq("type" => "ephemeral")
      end).to have_been_made
      expect(response.tool_uses.first["input"]).to eq("path" => "lib/x.rb")
      expect(response.stop_reason).to eq(:tool_use)
    end
  end
end
