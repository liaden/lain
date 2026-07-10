# frozen_string_literal: true

require "lain/provider/http"

# New spec, not a port -- upstream's streaming coverage is entirely VCR
# cassettes (which this branch does not add) plus the accumulator spec (ported
# separately). This proves the base SSE engine (streaming.rb) is wired into
# Provider#complete: given a block, it must actually stream -- feed an SSE
# body through EventStreamParser, accumulate the deltas, yield each chunk, and
# return one Message -- rather than raise NoMethodError on an undefined
# `stream_response`. WebMock (global, blocking network by default) delivers
# the recorded event-stream body to Faraday's on_data callback.
RSpec.describe Lain::Provider::HTTP::Streaming do
  # A minimal but real Anthropic message stream: start (with model + input
  # tokens), two text deltas, a usage delta, stop.
  def sse_body
    <<~SSE
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":0}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

      event: message_delta
      data: {"type":"message_delta","delta":{},"usage":{"output_tokens":5}}

      event: message_stop
      data: {"type":"message_stop"}

    SSE
  end

  def anthropic_provider
    config = Lain::Provider::HTTP::Configuration.new
    config.anthropic_api_key = "sk-ant-test"
    Lain::Provider::HTTP::Providers::Anthropic.new(config)
  end

  def model
    Struct.new(:id, :max_tokens).new("claude-opus-4-8", 1024)
  end

  before do
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse_body)
  end

  it "streams a block through Provider#complete rather than raising" do
    provider = anthropic_provider
    yielded = []

    message = provider.complete([Lain::Provider::HTTP::Message.new(role: :user, content: "hi")],
                                tools: {}, temperature: nil, model: model) { |chunk| yielded << chunk }

    expect(message).to be_a(Lain::Provider::HTTP::Message)
    expect(message.content).to eq("Hello world")
    expect(yielded).not_to be_empty
    expect(yielded).to all(be_a(Lain::Provider::HTTP::Chunk))
  end

  it "accumulates streamed usage onto the returned message" do
    message = anthropic_provider.complete([Lain::Provider::HTTP::Message.new(role: :user, content: "hi")],
                                          tools: {}, temperature: nil, model: model) { |_chunk| nil }

    expect(message.input_tokens).to eq(10)
    expect(message.output_tokens).to eq(5)
  end

  it "raises a typed error when the stream carries an error event" do
    # Exercises Streaming::ErrorHandling dispatching to Anthropic::Streaming's
    # own parse_streaming_error (overloaded_error -> 529 -> OverloadedError).
    stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
      status: 200,
      headers: { "Content-Type" => "text/event-stream" },
      body: %(event: error\ndata: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}\n\n)
    )

    expect do
      anthropic_provider.complete([Lain::Provider::HTTP::Message.new(role: :user, content: "hi")],
                                  tools: {}, temperature: nil, model: model) { |_chunk| nil }
    end.to raise_error(Lain::Provider::HTTP::OverloadedError)
  end
end
