# frozen_string_literal: true

require "faraday"
require "net/http"
require "socket"

# The instrument, driven by a real client over a real socket -- which is the only
# way to check the one thing it exists for. WebMock hands a stubbed body back as
# ONE chunk (spec/lain/provider/ollama/streamed_failure_spec.rb:5-9 says so, and
# it is why T10/T11 could not be written against it), so a spec that proved this
# harness under WebMock would prove nothing about it.
#
# Untagged with `:vcr`, and deliberately: a cassette that is REPLAYING makes
# NetworkAccess.permit_loopback inert, and the resulting refusal names neither
# the port nor the cassette. See spec/support/network_access.rb.
RSpec.describe StreamingUpstream, :seam do
  # Faraday's `:net_http` adapter is what every provider in this repo streams
  # through (connection/middleware_stack.rb:100), so Net::HTTP is the honest
  # client to observe chunk boundaries with -- one layer below the provider,
  # same socket behaviour. `read_timeout:` is only for the stall shapes.
  # @return [Array(Array<String>, StandardError, nil)] the chunks as they were
  #   handed over, and whatever ended the stream -- nil for a clean end. Both
  #   halves matter to every example here: a reset that arrived with no chunks
  #   and a reset that arrived after two are different instruments.
  def read_stream(url, path: "/api/chat", read_timeout: nil)
    chunks = []
    stream_into(chunks, URI(url), path, read_timeout)
    [chunks, nil]
  rescue StandardError => e
    [chunks, e]
  end

  def stream_into(chunks, uri, path, read_timeout)
    Net::HTTP.start(uri.host, uri.port, read_timeout:) do |http|
      http.request(streaming_post(path)) { |response| response.read_body { |chunk| chunks << chunk } }
    end
  end

  # Monotonic seconds from the request going out to the FIRST chunk arriving --
  # the quantity a first-byte grace is measured against, and the one a `.pause`
  # ahead of any chunk is supposed to move. A separate reader from `read_stream`
  # because the two want different things off the same socket: the bytes, and
  # when they showed up. Timing is the entire content of T12's ACs and it is the
  # one dimension a chunk-collecting reader cannot see.
  def time_to_first_chunk(url, path: "/api/chat")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    first_chunk_at(URI(url), path) - started
  end

  def first_chunk_at(uri, path)
    arrived = nil
    Net::HTTP.start(uri.host, uri.port, read_timeout: 5) do |http|
      http.request(streaming_post(path)) do |response|
        response.read_body { |_chunk| arrived ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end
    end
    arrived
  end

  # "content_block_delta/1" -- the event type and, where there is one, the block
  # index. Enough to say which blocks a prefix opened and which it closed.
  def frame_types(frames)
    frames.map { |frame| JSON.parse(frame.split("data: ", 2).last).values_at("type", "index").compact.join("/") }
  end

  def streaming_post(path)
    Net::HTTP::Post.new(path).tap do |request|
      request["Content-Type"] = "application/json"
      request.body = JSON.generate("model" => "probe", "stream" => true)
    end
  end

  let(:wire) { StreamingUpstream::Wire }
  let(:alpha) { wire.ollama_content("alpha") }
  let(:beta) { wire.ollama_content("beta") }
  let(:gamma) { wire.ollama_content("gamma") }
  let(:done) { wire.ollama_done(text_response("")) }

  describe "a complete scripted NDJSON stream" do
    it "delivers every scripted chunk, on its own boundary, in order" do
      served = nil
      described_class.ndjson(described_class.script.chunks(alpha, beta, gamma, done).close) do |upstream|
        served, = read_stream(upstream.url)
      end

      expect(served).to eq([alpha, beta, gamma, done])
    end

    it "terminates the stream normally" do
      failure = :never_assigned
      described_class.ndjson(described_class.script.chunks(alpha, done).close) do |upstream|
        _, failure = read_stream(upstream.url)
      end

      expect(failure).to be_nil
    end

    it "reassembles through the real Ollama assembler into one body" do
      served = nil
      described_class.ndjson(described_class.script.chunks(alpha, beta, gamma, done).close) do |upstream|
        served, = read_stream(upstream.url)
      end
      assembler = Lain::Provider::Ollama::StreamAssembler.new
      served.each { |chunk| assembler.feed(chunk) }

      expect(assembler.result.dig("message", "content")).to eq("alphabetagamma")
    end
  end

  describe "severing a connection mid-body" do
    it "resets the connection rather than ending the stream cleanly" do
      failure = nil
      described_class.ndjson(described_class.script.chunks(alpha, beta).sever) do |upstream|
        _, failure = read_stream(upstream.url)
      end

      expect(failure).to be_a(Errno::ECONNRESET)
    end

    # The measured half, and the one the retry cards depend on: a RST that also
    # destroyed the bytes already delivered would make T10/T11 vacuous, because
    # the splice they hunt needs the abandoned attempt to have REACHED the
    # assembler. Linux drains the receive queue before surfacing the reset --
    # 20/20 at a zero settle delay when this was measured.
    it "delivers the chunks scripted before the sever" do
      served = nil
      described_class.ndjson(described_class.script.chunks(alpha, beta).sever) do |upstream|
        served, = read_stream(upstream.url)
      end

      expect(served).to eq([alpha, beta])
    end

    it "never delivers the done marker it was not scripted to send" do
      served = nil
      described_class.ndjson(described_class.script.chunks(alpha, beta).sever) do |upstream|
        served, = read_stream(upstream.url)
      end

      expect(served.join).not_to include('"done":true')
    end
  end

  describe "scripting successive connections differently" do
    it "severs the first connection partway through its scripted body" do
      first = nil
      described_class.ndjson(described_class.script.chunk(alpha).sever,
                             described_class.script.chunks(gamma, done).close) do |upstream|
        first = read_stream(upstream.url)
        read_stream(upstream.url)
      end

      expect(first).to match([[alpha], an_instance_of(Errno::ECONNRESET)])
    end

    it "delivers the second connection's full scripted body" do
      second = nil
      described_class.ndjson(described_class.script.chunk(alpha).sever,
                             described_class.script.chunks(gamma, done).close) do |upstream|
        read_stream(upstream.url)
        second = read_stream(upstream.url)
      end

      expect(second).to eq([[gamma, done], nil])
    end

    # Matching OllamaWire::QueueTransport and Provider::Mock: a script queue that
    # runs out repeats its last entry, so "severs EVERY connection" (T10's
    # exhausted-budget scenario, T12's not-retried one) is one script, not four.
    it "repeats the last script once the queue is exhausted" do
      failures = []
      described_class.ndjson(described_class.script.chunk(alpha).sever) do |upstream|
        3.times { failures << read_stream(upstream.url).last }
      end

      expect(failures).to all(be_a(Errno::ECONNRESET))
    end

    it "records one request per connection served" do
      count = nil
      described_class.ndjson(described_class.script.chunks(alpha, done).close) do |upstream|
        2.times { read_stream(upstream.url) }
        count = upstream.requests.size
      end

      expect(count).to eq(2)
    end

    it "records what the client actually posted, so a consumer can assert on the payload" do
      posted = nil
      described_class.ndjson(described_class.script.chunks(alpha, done).close) do |upstream|
        read_stream(upstream.url)
        posted = upstream.requests.first
      end

      expect(posted).to have_attributes(verb: "POST", path: "/api/chat",
                                        body: a_string_including('"model":"probe"'))
    end
  end

  describe "the SSE dialect" do
    let(:message_start) { wire.sse_frame("type" => "message_start", "message" => { "id" => "msg_seam" }) }
    let(:first_delta) do
      wire.sse_frame("type" => "content_block_delta", "index" => 0,
                     "delta" => { "type" => "text_delta", "text" => "al" })
    end
    let(:second_delta) do
      wire.sse_frame("type" => "content_block_delta", "index" => 0,
                     "delta" => { "type" => "text_delta", "text" => "pha" })
    end

    it "delivers each event as its own SSE frame" do
      served = nil
      described_class.sse(described_class.script.chunks(message_start, first_delta, second_delta).close) do |upstream|
        served, = read_stream(upstream.url)
      end

      expect(served).to eq([message_start, first_delta, second_delta])
    end

    it "frames an event the way the wire does" do
      expect(first_delta).to eq(%(event: content_block_delta\ndata: #{JSON.generate(
        "type" => "content_block_delta", "index" => 0, "delta" => { "type" => "text_delta", "text" => "al" }
      )}\n\n))
    end

    # The reuse, pinned: one frame per AnthropicSSE event, and the concatenation
    # is byte-identical to the body that helper already builds. That is what lets
    # T11 script "open two blocks, then sever" as a prefix of a real response.
    it "splits a whole Response into one frame per AnthropicSSE event" do
      response = tool_response(["toolu_seam", "echo", { "text" => "hi" }])

      expect(wire.sse_frames(response).join).to eq(AnthropicSSE.body(response))
    end

    # The exact prefix T11's phantom-tool-call AC needs, pinned so it cannot
    # drift -- and it is easy to get wrong in the direction that passes. Frames
    # are start/delta/stop PER BLOCK, so for a two-block response the prefix that
    # leaves the SECOND block open is SIX frames, not four. Taking four serves
    # `message_start` plus a block that is fully CLOSED: a T11 example built on
    # that would assert "no orphaned tool_use survived" and pass because no
    # orphan was ever opened.
    it "can serve a prefix that leaves the second block open" do
      rich = Lain::Response.new(content: [{ "type" => "text", "text" => "partial prose" },
                                          { "type" => "tool_use", "id" => "toolu_orphan",
                                            "name" => "echo", "input" => { "text" => "hi" } }],
                                stop_reason: :tool_use)

      expect(frame_types(wire.sse_frames(rich)).take(6))
        .to eq(["message_start", "content_block_start/0", "content_block_delta/0", "content_block_stop/0",
                "content_block_start/1", "content_block_delta/1"])
    end

    it "serves the content type the dialect names" do
      served = nil
      described_class.sse(described_class.script.chunk(message_start).close) do |upstream|
        served = Faraday.new(upstream.url).post("v1/messages").headers["content-type"]
      end

      expect(served).to eq("text/event-stream")
    end
  end

  # The three shapes T12 needs that are neither a clean stream nor a sever.
  describe "a stream that stops emitting without closing" do
    it "leaves the client waiting after the chunks it did send" do
      served = nil
      failure = nil
      described_class.ndjson(described_class.script.chunks(alpha, beta).stall) do |upstream|
        served, failure = read_stream(upstream.url, read_timeout: 0.3)
      end

      expect([served, failure]).to match([[alpha, beta], an_instance_of(Net::ReadTimeout)])
    end
  end

  describe "a delay before the first chunk" do
    it "streams normally once the delay has passed" do
      served = nil
      described_class.ndjson(described_class.script.pause(0.2).chunks(alpha, done).close) do |upstream|
        served, = read_stream(upstream.url, read_timeout: 5)
      end

      expect(served).to eq([alpha, done])
    end

    # Without this the pause is unpinned: every other example asserts only that
    # chunks ARRIVE, which they do instantly whether or not `Pause#emit` sleeps.
    # T12's ACs are entirely about elapsed time, so the clock needs a guard of
    # its own or the dimension those cards rest on is untested here.
    it "holds the first chunk back for at least the scripted pause" do
      waited = nil
      described_class.ndjson(described_class.script.pause(0.2).chunks(alpha, done).close) do |upstream|
        waited = time_to_first_chunk(upstream.url)
      end

      expect(waited).to be >= 0.2
    end
  end

  describe "a slow but living stream" do
    it "delivers every chunk when each is separated by a pause" do
      served = nil
      script = described_class.script.chunk(alpha).pause(0.1).chunk(beta).pause(0.1).chunk(done).close
      described_class.ndjson(script) do |upstream|
        served, = read_stream(upstream.url, read_timeout: 5)
      end

      expect(served).to eq([alpha, beta, done])
    end

    it "spends at least the scripted pauses getting there" do
      spent = nil
      script = described_class.script.chunk(alpha).pause(0.1).chunk(beta).pause(0.1).chunk(done).close
      described_class.ndjson(script) do |upstream|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        read_stream(upstream.url, read_timeout: 5)
        spent = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      expect(spent).to be >= 0.2
    end
  end

  describe "the client the consumers actually use" do
    it "reaches the upstream through a real Faraday connection with on_data" do
      served = []
      described_class.ndjson(described_class.script.chunks(alpha, beta, done).close) do |upstream|
        connection = Faraday.new(upstream.url) { |f| f.adapter :net_http }
        connection.post("api/chat") do |request|
          request.options.on_data = ->(chunk, _size, _env = nil) { served << chunk }
        end
      end

      expect(served).to eq([alpha, beta, done])
    end
  end

  describe "lifecycle" do
    it "yields a url on the loopback address it bound" do
      seen = nil
      described_class.ndjson(described_class.script.chunk(alpha).close) { |upstream| seen = upstream.url }

      expect(seen).to match(%r{\Ahttp://127\.0\.0\.1:\d+\z})
    end

    it "leaves no server thread of its own alive" do
      described_class.ndjson(described_class.script.chunks(alpha, beta).stall) do |upstream|
        read_stream(upstream.url, read_timeout: 0.1)
      end

      expect(Thread.list.select(&:alive?).filter_map(&:name))
        .to all(satisfy { |name| !name.start_with?(StreamingUpstream::THREAD_PREFIX) })
    end

    it "leaves nothing listening on the port it bound" do
      port = nil
      described_class.ndjson(described_class.script.chunk(alpha).close) { |upstream| port = upstream.port }

      expect { TCPSocket.new("127.0.0.1", port).close }.to raise_error(Errno::ECONNREFUSED)
    end

    it "closes the port even when the block raises" do
      port = nil
      expect do
        described_class.ndjson(described_class.script.chunk(alpha).close) do |upstream|
          port = upstream.port
          raise "the example blew up mid-stream"
        end
      end.to raise_error("the example blew up mid-stream")
      expect { TCPSocket.new("127.0.0.1", port).close }.to raise_error(Errno::ECONNREFUSED)
    end

    # The permission is the harness's to take and the harness's to give back: it
    # can only be taken AFTER the bind (port 0 is not knowable earlier), and a
    # harness that left it held would quietly widen the suite's posture.
    it "restores the offline posture for its port once the block ends" do
      port = nil
      described_class.ndjson(described_class.script.chunk(alpha).close) { |upstream| port = upstream.port }

      expect { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }
        .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
    end
  end

  # WebMock strips the caller's block from the request it ALLOWS and replays the
  # body afterwards in one piece, so every boundary assertion above depends on
  # `RealStreaming` running the unpatched `Net::HTTP#request` instead. These two
  # pin the narrowing: it takes effect only where NetworkAccess already said yes,
  # and it opens nothing else. Deleting the hook makes the boundary examples go
  # red; widening it makes these go red.
  describe "the WebMock bypass" do
    it "still refuses a loopback port that was never permitted" do
      other = nil
      described_class.ndjson(described_class.script.chunk(alpha).close) do |_upstream|
        idle = TCPServer.new("127.0.0.1", 0)
        begin
          other = read_stream("http://127.0.0.1:#{idle.addr[1]}").last
        ensure
          idle.close
        end
      end

      expect(other).to be_a(VCR::Errors::UnhandledHTTPRequestError)
    end

    it "hands the permitted request to the real Net::HTTP rather than WebMock's replay" do
      webmocked = nil
      described_class.ndjson(described_class.script.chunks(alpha, done).close) do |upstream|
        uri = URI(upstream.url)
        Net::HTTP.start(uri.host, uri.port) do |http|
          http.request(Net::HTTP::Post.new("/api/chat")) do |response|
            webmocked = response.singleton_class.ancestors.include?(Net::WebMockHTTPResponse)
            response.read_body { |_chunk| nil }
          end
        end
      end

      expect(webmocked).to be(false)
    end

    # The predicate runs for EVERY Net::HTTP request in a worker that has served
    # one upstream, and the prepend is permanent -- so an address it cannot
    # classify has to answer false, not raise. Each of these is accepted by
    # `Net::HTTP.new` and rejected by `URI`, which the predicate used to build:
    # one of them anywhere in a worker would have taken down an unrelated
    # request with a `URI` error naming neither WebMock nor this harness, and
    # only when the example order put the two together.
    # No `RealStreaming.install` here, deliberately: `streaming?` is a pure
    # predicate and needs no prepend, but installing is PERMANENT and
    # process-wide -- so an install from this example would, under some seeds,
    # arm the mechanism before the examples whose whole job is to detect its
    # absence. That turned "comment out one line, watch 10 go red" into a
    # seed-dependent 3-to-10, which is this card's central proof made unreliable
    # by an inert line.
    it "answers false rather than raising for an address Net::HTTP takes and URI does not" do
      hostile = ["127.0.0.1 ", "", "not a host", "%zz", "[::1",
                 "user:pw@evil.example.com", "evil.example.com#localhost"]

      verdicts = hostile.map { |address| described_class::RealStreaming.streaming?(Net::HTTP.new(address, 9)) }

      expect(verdicts).to all(be(false))
    end
  end

  describe ".script" do
    it "builds each step without mutating the script it was built from" do
      base = described_class.script.chunk(alpha)
      base.chunk(beta).sever

      expect(base).to eq(described_class.script.chunk(alpha))
    end

    # A zero-length chunk IS the chunked-encoding terminator, so an empty one
    # ends the stream cleanly and overrides the ending the script names --
    # `.chunk("").chunk(body).sever` delivered zero chunks and no error, which
    # is a clean SUCCESS from a script that says "sever". Refused at
    # construction, where a reader can see why.
    it "refuses an empty chunk, which would end the stream rather than add to it" do
      expect { described_class.script.chunk("") }
        .to raise_error(ArgumentError, /cannot be empty/)
    end
  end
end
