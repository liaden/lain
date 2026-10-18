# frozen_string_literal: true

# Drives the live streaming path, {Lain::Provider::Anthropic::Transport}, over
# WebMock: the SSE engine in streaming.rb must turn each failure shape into its
# typed error, and a truncated stream must not read as a successful empty turn.
RSpec.describe Lain::Provider::HTTP::Streaming do
  def sse_body
    <<~SSE
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":0}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      event: message_stop
      data: {"type":"message_stop"}

    SSE
  end

  def transport
    # Zeroed retry sleeps: the error-event examples raise OverloadedError,
    # which faraday-retry retries with real backoff before it surfaces.
    config = zero_retry_config
    config.anthropic_api_key = "sk-ant-test"
    Lain::Provider::Anthropic::Transport.new(config)
  end

  def error_event_data
    %({"type":"error","error":{"type":"overloaded_error","message":"overloaded"}})
  end

  def stub_stream(body, content_type: "text/event-stream")
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, headers: { "Content-Type" => content_type }, body:)
  end

  def consume(events = [])
    transport.stream({ model: "claude-opus-4-8", stream: true }) { |event| events << event }
    events
  end

  def swallowed(events)
    "no error raised: stream yielded #{events.size} events -- a successful empty turn"
  end

  it "yields each parsed event of a clean stream" do
    stub_stream(sse_body)

    expect(consume.map { _1["type"] }).to eq(%w[message_start content_block_delta message_stop])
  end

  it "surfaces a 401 from the sync path as UnauthorizedError" do
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 401, headers: { "Content-Type" => "application/json" },
                 body: { error: { type: "authentication_error", message: "invalid x-api-key" } }.to_json)

    expect { transport.sync_post({ model: "claude-opus-4-8" }) }
      .to raise_error(Lain::Provider::HTTP::UnauthorizedError)
  end

  it "raises a typed error when the stream carries an error event" do
    stub_stream("event: error\ndata: #{error_event_data}\n\n")

    expect { consume }.to raise_error(Lain::Provider::HTTP::OverloadedError)
  end

  # The bug class a stubbed body cannot reach: WebMock's Net::HTTP adapter hands
  # the whole body to `read_body` in ONE yield, so `on_data` never sees a
  # fragment boundary. The boundary is what matters, so feed Transport's own
  # `on_data` handler the fragments one at a time.
  it "raises exactly one typed error when the error event is split across two chunks" do
    events = []
    errors = []
    handler = transport.send(:sse_handler) { |data| events << data }
    env = Faraday::Env.from(status: 200)

    ["event: error\n", "data: #{error_event_data}\n\n"].each do |fragment|
      handler.call(fragment, 0, env)
    rescue Lain::Provider::HTTP::OverloadedError => e
      errors << e
    end

    expect([errors.size, events]).to eq([1, []])
  end

  it "raises a typed error for a bare JSON error body with no SSE framing" do
    stub_stream(error_event_data, content_type: "application/json")

    expect { consume }.to raise_error(Lain::Provider::HTTP::OverloadedError)
  end

  it "raises the typed error when the stream ends with no trailing newline at all" do
    stub_stream("event: error\ndata: #{error_event_data}")
    events = []

    expect { consume(events) }.to raise_error(Lain::Provider::HTTP::OverloadedError), -> { swallowed(events) }
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

    # `v2_on_data` (faraday_handlers.rb) has a SECOND caller
    # besides Faraday itself -- {Streaming#flush_stream} above, which hands it
    # `response.env` rather than an env Faraday produced. `Faraday::Response#env`
    # is nil until `#finish` runs, so a response reaching flush_stream
    # unfinished crashes on the bare `env.status` this card's deletion left
    # behind, where the deleted `env&.status` used to route it (nil != 200) to
    # `on_failed_response` instead. Production-safe today -- the net_http
    # adapter finishes the env before `connection.post` returns, so
    # flush_stream never actually sees this -- but pinned so a future adapter
    # or refactor that CAN reach it hits a named spec, not a bare
    # NoMethodError three frames from here.
    it "raises if flush_stream is ever handed a response that never finished" do
      handler = streaming_host.send(:build_on_data_handler) { |_chunk| nil }

      expect { streaming_host.send(:flush_stream, handler, Faraday::Response.new) }
        .to raise_error(NoMethodError, /status/)
    end
  end
end
