# frozen_string_literal: true

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
    # Zeroed retry sleeps: the error-event example below raises OverloadedError,
    # which faraday-retry retries with real backoff before it surfaces.
    config = zero_retry_config
    config.anthropic_api_key = "sk-ant-test"
    Lain::Provider::HTTP::Providers::Anthropic.new(config)
  end

  def model
    Struct.new(:id, :max_tokens).new("claude-opus-4-8", 1024)
  end

  def error_event_data
    %({"type":"error","error":{"type":"overloaded_error","message":"overloaded"}})
  end

  def stub_stream(body, content_type: "text/event-stream")
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, headers: { "Content-Type" => content_type }, body:)
  end

  # Faraday's `on_data` proc, fed one fragment at a time.
  def deliver_fragments(*fragments)
    env = Faraday::Env.from(status: 200)
    handler = anthropic_provider.send(:handle_stream) { |_chunk| nil }
    fragments.each { |fragment| handler.call(fragment, 0, env) }
  end

  def swallowed(returned)
    "no error raised: complete returned content=#{returned&.content.inspect}, " \
      "input_tokens=#{returned&.input_tokens.inspect} -- a successful empty turn"
  end

  def complete_streaming(&block)
    anthropic_provider.complete([Lain::Provider::HTTP::Message.new(role: :user, content: "hi")],
                                tools: {}, temperature: nil, model:) { |chunk| block&.call(chunk) }
  end

  before { stub_stream(sse_body) }

  it "streams a block through Provider#complete rather than raising" do
    yielded = []

    message = complete_streaming { |chunk| yielded << chunk }

    expect(message).to be_a(Lain::Provider::HTTP::Message)
    expect(message.content).to eq("Hello world")
    expect(yielded).not_to be_empty
    expect(yielded).to all(be_a(Lain::Provider::HTTP::Chunk))
  end

  it "accumulates streamed usage onto the returned message" do
    message = complete_streaming

    expect(message.input_tokens).to eq(10)
    expect(message.output_tokens).to eq(5)
  end

  it "raises a typed error when the stream carries an error event" do
    # Exercises Streaming::ErrorHandling dispatching to Anthropic::Streaming's
    # own parse_streaming_error (overloaded_error -> 529 -> OverloadedError).
    stub_stream("event: error\ndata: #{error_event_data}\n\n")

    expect { complete_streaming }.to raise_error(Lain::Provider::HTTP::OverloadedError)
  end

  # The bug class a stubbed body cannot reach: WebMock's Net::HTTP adapter hands
  # the whole body to `read_body` in ONE yield, so `on_data` never sees a
  # fragment boundary. The boundary is what matters here -- the parser
  # `handle_stream` closes over is the thing that buffers across feeds -- so
  # drive that proc directly, as the Ollama streaming spec replays scripted byte
  # chunks through its transport double.
  it "raises the typed error when the error event is split across two chunks" do
    expect { deliver_fragments("event: error\n", "data: #{error_event_data}\n\n") }
      .to raise_error(Lain::Provider::HTTP::OverloadedError)
  end

  it "raises a typed error for a bare JSON error body with no SSE framing" do
    # The non-SSE shape: some 200 responses carry a raw error object instead of
    # an event stream, which never reaches the parser and so keeps its own
    # branch (json_error_payload?).
    stub_stream(error_event_data, content_type: "application/json")

    expect { complete_streaming }.to raise_error(Lain::Provider::HTTP::OverloadedError)
  end

  # Truncation, not fragmentation: the server writes the error event and closes
  # the connection before the terminating blank line. The SSE spec says an
  # incomplete event is discarded, so without an end-of-stream flush the parser
  # drops it -- and a dropped error is not an exception, it is a successful
  # empty turn written into the Journal. The failure message names that, because
  # "nothing was raised" is the whole defect.
  it "raises the typed error when the stream ends before the event's blank line" do
    stub_stream("event: error\ndata: #{error_event_data}\n")
    returned = nil

    expect { returned = complete_streaming }.to raise_error(Lain::Provider::HTTP::OverloadedError),
                                                -> { swallowed(returned) }
  end

  it "raises the typed error when the stream ends with no trailing newline at all" do
    stub_stream("event: error\ndata: #{error_event_data}")
    returned = nil

    expect { returned = complete_streaming }.to raise_error(Lain::Provider::HTTP::OverloadedError),
                                                -> { swallowed(returned) }
  end

  # `post_stream`'s `flush:` keyword, pinned on its own contract rather than
  # only through the four ResponseWal examples that fail downstream when it is
  # wrong. A caller that WRAPS the handler to record what arrives -- Anthropic
  # tees every wire chunk into the WAL frame -- must name the unwrapped handler,
  # because the flush's blank line is ours and never came off the wire. The
  # default is the unsafe direction for exactly that caller, so the next
  # transport to wrap a handler should fail here, not in someone else's spec.
  describe "#post_stream flush:" do
    def streaming_host
      Class.new { include Lain::Provider::HTTP::Streaming }.new
    end

    # Stands in for Faraday: runs the request-shaping block, returns a response
    # carrying an env, and never touches the network.
    def stub_connection
      response = Struct.new(:env).new(Faraday::Env.from(status: 200))
      Class.new do
        define_method(:post) do |_url, _payload, &configure|
          configure.call(Struct.new(:options, :headers).new(Faraday::RequestOptions.new, {}))
          response
        end
      end.new
    end

    def post_through(on_data, **flush)
      streaming_host.send(:post_stream, stub_connection, "/v1/messages", "{}", on_data, **flush)
    end

    def recording_wrapper(recorded)
      proc { |chunk, *_rest| recorded << chunk }
    end

    it "keeps the flush out of a wrapper named by flush:" do
      recorded = []

      post_through(recording_wrapper(recorded), flush: ->(_chunk, _bytes, _env) {})

      expect(recorded).to be_empty
    end

    it "sends the flush through the wrapper when flush: is omitted" do
      recorded = []

      post_through(recording_wrapper(recorded))

      expect(recorded).to eq(["\n\n"])
    end
  end
end
