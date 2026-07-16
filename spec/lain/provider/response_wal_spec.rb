# frozen_string_literal: true

require "tmpdir"
require "webmock/rspec"

RSpec.describe Lain::Provider::ResponseWal do
  around do |example|
    Dir.mktmpdir("wal") { |dir| @dir = dir and example.run }
  end

  def wal(name = "session", **opts)
    described_class.new(File.join(@dir, "#{name}.wal"), **opts)
  end

  describe "framing a written response" do
    it "round-trips the exact bytes, keyed by the request digest, marked complete" do
      subject = wal
      frame = subject.open_frame(request_digest: "sha256:abc")
      frame.append("event: message_start\n")
      frame.append("data: {\"x\":1}\n\n")
      frame.close(complete: true)

      entry = wal.frames.to_a.fetch(0)
      expect(entry.request_digest).to eq("sha256:abc")
      expect(entry.bytes).to eq("event: message_start\ndata: {\"x\":1}\n\n")
      expect(entry).to be_complete
    end

    it "preserves bytes verbatim even when they contain the terminator's newline shapes" do
      subject = wal
      raw = "data: {\"a\":\"line1\nline2\"}\n\n\n"
      frame = subject.open_frame(request_digest: "d")
      frame.append(raw)
      frame.close(complete: true)

      entry = wal.frames.to_a.fetch(0)
      expect(entry.bytes).to eq(raw)
      expect(entry).to be_complete
    end

    it "keeps each frame of a multi-request session independent" do
      subject = wal
      %w[one two three].each do |digest|
        frame = subject.open_frame(request_digest: digest)
        frame.append("body-#{digest}")
        frame.close(complete: true)
      end

      entries = wal.frames.to_a
      expect(entries.map(&:request_digest)).to eq(%w[one two three])
      expect(entries.map(&:bytes)).to eq(%w[body-one body-two body-three])
      expect(entries).to all(be_complete)
    end
  end

  describe "recovering a torn tail" do
    it "reads a header-only frame (crash before any bytes) as incomplete" do
      subject = wal
      subject.open_frame(request_digest: "torn")
      # no append, no close -- process died right after the header line

      entry = wal.frames.to_a.fetch(0)
      expect(entry.request_digest).to eq("torn")
      expect(entry).not_to be_complete
    end

    it "reads a mid-bytes cut as incomplete while every prior frame stays intact" do
      subject = wal
      good = subject.open_frame(request_digest: "good")
      good.append("all-of-it")
      good.close(complete: true)
      cut = subject.open_frame(request_digest: "cut")
      cut.append("half-written") # never closed: no terminator

      entries = wal.frames.to_a
      expect(entries.size).to eq(2)
      expect(entries.first).to be_complete
      expect(entries.first.bytes).to eq("all-of-it")
      expect(entries.last.request_digest).to eq("cut")
      expect(entries.last.bytes).to eq("half-written")
      expect(entries.last).not_to be_complete
    end

    it "treats a terminator whose byte count disagrees with the bytes as incomplete" do
      path = File.join(@dir, "mismatch.wal")
      rs = described_class::RECORD_SEPARATOR
      # A terminator claiming 999 bytes over an 8-byte body: a torn terminator.
      File.binwrite(path, "#{rs}#{JSON.generate("request_digest" => "m", "at" => "t")}\neight-ish" \
                          "#{rs}#{JSON.generate("bytes" => 999, "complete" => true)}\n")

      entry = described_class.new(path).frames.to_a.fetch(0)
      expect(entry).not_to be_complete
    end

    it "treats an explicit complete:false terminator as incomplete" do
      path = File.join(@dir, "false.wal")
      rs = described_class::RECORD_SEPARATOR
      File.binwrite(path, "#{rs}#{JSON.generate("request_digest" => "f", "at" => "t")}\nbody" \
                          "#{rs}#{JSON.generate("bytes" => 4, "complete" => false)}\n")

      entry = described_class.new(path).frames.to_a.fetch(0)
      expect(entry).not_to be_complete
    end

    it "yields nothing for a WAL file that was never written" do
      expect(wal("absent").frames.to_a).to be_empty
    end
  end

  # A frame can be left terminator-less in the MIDDLE of the file -- retry
  # exhaustion or a terminal error abandons it and the session keeps writing,
  # or a SIGKILL tears it and --resume reopens the same file. The reader must
  # resync on the next header instead of blind-pairing records, or every later
  # frame is silently destroyed.
  describe "resync after a terminator-less frame mid-file" do
    it "marks the abandoned frame incomplete and reads every later frame intact" do
      subject = wal
      abandoned = subject.open_frame(request_digest: "req-failed")
      abandoned.append("partial bytes from a dropped stream")
      # no close: the exception path left it open and the session continued
      %w[req-next req-third].each do |digest|
        frame = subject.open_frame(request_digest: digest)
        frame.append("body-#{digest}")
        frame.close(complete: true)
      end

      entries = wal.frames.to_a
      expect(entries.map(&:request_digest)).to eq(%w[req-failed req-next req-third])
      expect(entries.first.bytes).to eq("partial bytes from a dropped stream")
      expect(entries.first).not_to be_complete
      expect(entries.drop(1)).to all(be_complete)
      expect(entries.last.bytes).to eq("body-req-third")
    end

    it "survives a SIGKILL-torn tail across a reopen: resumed frames stay readable" do
      first_session = wal
      turn = first_session.open_frame(request_digest: "turn-1")
      turn.append("first turn body")
      turn.close(complete: true)
      torn = first_session.open_frame(request_digest: "turn-2-crashed")
      torn.append("partial before SIGKILL")
      # SIGKILL here: no close, no fsync beyond the unbuffered writes

      resumed = wal
      %w[resumed-3 resumed-4].each do |digest|
        frame = resumed.open_frame(request_digest: digest)
        frame.append("resumed-#{digest}")
        frame.close(complete: true)
      end
      resumed.close

      entries = wal.frames.to_a
      expect(entries.map(&:request_digest)).to eq(%w[turn-1 turn-2-crashed resumed-3 resumed-4])
      expect(entries.map(&:complete?)).to eq([true, false, true, true])
      expect(entries[1].bytes).to eq("partial before SIGKILL")
      expect(entries.last.bytes).to eq("resumed-resumed-4")
    end

    it "refuses loudly when a payload smuggles the record separator mid-file" do
      subject = wal
      smuggler = subject.open_frame(request_digest: "has_rs")
      smuggler.append("before#{described_class::RECORD_SEPARATOR}after")
      smuggler.close(complete: true)

      expect { wal.frames.to_a }.to raise_error(described_class::CorruptFrame)
    end
  end

  # T17w blocker: the main Agent and every parallel subagent share ONE spool,
  # and subagents fan out as sibling async fibers that yield on socket IO
  # BETWEEN writes. Two frames streaming to one file would interleave at record
  # granularity -- exactly the "bytes trail a terminator record" corruption the
  # Reader refuses, which would make a crashed parallel-subagent session
  # unresumable. Only one frame streams; every other fiber's frame buffers and
  # lands atomically, so no records ever interleave.
  describe "concurrent frames from different fibers" do
    # Steps two fibers through open/append/close the way the async scheduler
    # would -- yielding between every write, so the OLD single-shared-writer path
    # interleaves records here deterministically (and the Reader refuses them).
    def step(fiber) = fiber.resume

    it "keeps each fiber's frame contiguous when they open and append alternately" do
      subject = wal
      a = Fiber.new do
        frame = subject.open_frame(request_digest: "a")
        frame.append("a1")
        Fiber.yield
        frame.append("a2")
        Fiber.yield
        frame.close(complete: true)
      end
      b = Fiber.new do
        frame = subject.open_frame(request_digest: "b")
        frame.append("b1")
        Fiber.yield
        frame.append("b2")
        Fiber.yield
        frame.close(complete: true)
      end
      [a, b, a, b, a, b].each { |fiber| step(fiber) }
      subject.close

      entries = wal.frames.to_a
      expect(entries.map(&:request_digest)).to eq(%w[a b])
      expect(entries).to all(be_complete)
      expect(entries.map(&:bytes)).to eq(%w[a1a2 b1b2])
    end

    # A streaming frame ABANDONED terminator-less (terminal error / retry
    # exhaustion) is never closed, so its close never drains @pending. A COMPLETE
    # buffered sibling must still reach disk on a clean spool close -- losing a
    # paid-for response on a graceful exit (not even a SIGKILL) is the blocker.
    it "writes a completed buffered sibling even when the streaming frame is abandoned before spool close" do
      subject = wal
      streamer = Fiber.new do
        frame = subject.open_frame(request_digest: "streamer")
        frame.append("partial")
        # abandoned: a terminal error unwound the dispatch, the frame never closed
      end
      sibling = Fiber.new do
        frame = subject.open_frame(request_digest: "sibling")
        frame.append("complete-body")
        frame.close(complete: true)
      end
      step(streamer)  # streamer opens (streams), appends its partial, returns unclosed
      step(sibling)   # sibling opens (different fiber -> buffers), completes -> @pending
      subject.close   # clean exit MUST flush the pending sibling

      entries = wal.frames.to_a
      expect(entries.map(&:request_digest)).to eq(%w[streamer sibling])
      expect(entries.first).not_to be_complete # abandoned torn tail
      recovered = entries.find { |entry| entry.request_digest == "sibling" }
      expect(recovered).to be_complete
      expect(recovered.bytes).to eq("complete-body")
    end

    # A same-fiber takeover after abandonment must drain @pending FIRST, or the
    # completed sibling lands after the taker (wrong order) or is stranded.
    it "flushes a pending sibling before a same-fiber takeover, keeping every frame readable" do
      subject = wal
      streamer = subject.open_frame(request_digest: "streamer") # main fiber
      streamer.append("partial") # abandoned, never closed
      Fiber.new do
        frame = subject.open_frame(request_digest: "sibling")
        frame.append("sib-body")
        frame.close(complete: true) # buffers into @pending (streamer still live)
      end.resume
      taker = subject.open_frame(request_digest: "taker") # same fiber -> takeover
      taker.append("taker-body")
      taker.close(complete: true)
      subject.close

      entries = wal.frames.to_a
      expect(entries.map(&:request_digest)).to eq(%w[streamer sibling taker])
      expect(entries.map(&:complete?)).to eq([false, true, true])
      expect(entries.last.bytes).to eq("taker-body")
    end

    it "flushes a buffered frame that closes FIRST only once the streaming frame closes" do
      subject = wal
      streamer = Fiber.new do
        frame = subject.open_frame(request_digest: "streamer")
        frame.append("s1")
        Fiber.yield
        frame.append("s2")
        Fiber.yield
        frame.close(complete: true)
      end
      buffered = Fiber.new do
        frame = subject.open_frame(request_digest: "buffered")
        frame.append("whole")
        frame.close(complete: true) # closes while the streamer is still live
      end
      step(streamer)  # streamer opens (streams), s1
      step(buffered)  # buffered opens (different fiber -> buffers), appends, closes -> pending
      step(streamer)  # s2
      step(streamer)  # streamer closes -> writes its terminator, then drains the buffered blob
      subject.close

      entries = wal.frames.to_a
      expect(entries.map(&:request_digest)).to eq(%w[streamer buffered])
      expect(entries).to all(be_complete)
      expect(entries.map(&:bytes)).to eq(%w[s1s2 whole])
    end
  end

  describe "durability" do
    it "fsyncs on frame close and whenever the mid-stream watermark is crossed" do
      subject = wal(fsync_watermark: 8)
      expect_any_instance_of(File).to receive(:fsync).at_least(:twice).and_call_original

      frame = subject.open_frame(request_digest: "d")
      frame.append("0123456789") # 10 bytes > 8-byte watermark -> one mid-stream fsync
      frame.close(complete: true) # + one on close

      expect(wal.frames.to_a.fetch(0).bytes).to eq("0123456789")
    end
  end
end

RSpec.describe Lain::Provider::Spool::RotatingFrame do
  around do |example|
    Dir.mktmpdir("wal-rotate") { |dir| @dir = dir and example.run }
  end

  let(:path) { File.join(@dir, "session.wal") }

  it "closes the attempt underway as aborted and opens a fresh frame for the same digest" do
    wal = Lain::Provider::ResponseWal.new(path)
    frame = described_class.new(spool: wal, request_digest: "d")
    frame.append("partial-")
    frame.rotate
    frame.append("whole")
    frame.close(complete: true)
    wal.close

    entries = Lain::Provider::ResponseWal.new(path).frames.to_a
    expect(entries.map(&:request_digest)).to eq(%w[d d])
    expect(entries.first.bytes).to eq("partial-")
    expect(entries.first).not_to be_complete
    expect(entries.last.bytes).to eq("whole")
    expect(entries.last).to be_complete
  end

  it "stays free over the Null spool: rotation writes nothing anywhere" do
    frame = described_class.new(spool: Lain::Provider::Spool::Null.new, request_digest: "d")
    frame.append("bytes")
    frame.rotate
    frame.append("more")
    frame.close(complete: true)

    expect(Dir.children(@dir)).to be_empty
  end
end

RSpec.describe "spooling a provider response into a ResponseWal", :aggregate_failures do
  around do |example|
    Dir.mktmpdir("wal-io") { |dir| @dir = dir and example.run }
  end

  def path(name) = File.join(@dir, "#{name}.wal")

  def request(**overrides)
    Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  def stub_messages(status:, body:, content_type:)
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status:, body:, headers: { "Content-Type" => content_type })
  end

  let(:canned) do
    Lain::Response.new(id: "msg_1", model: "claude-opus-4-8", stop_reason: :end_turn,
                       content: [{ "type" => "text", "text" => "hello" }],
                       usage: Lain::Usage.new(input_tokens: 3, output_tokens: 2))
  end

  it "spools a streamed response verbatim, keyed by the request digest, marked complete" do
    sse = AnthropicSSE.body(canned)
    stub_messages(status: 200, body: sse, content_type: "text/event-stream")
    spool = Lain::Provider::ResponseWal.new(path("stream"))
    provider = Lain::Provider::AnthropicRaw.new(spool:, api_key: "test")

    req = request(stream: true)
    provider.complete(req)
    spool.close

    entry = Lain::Provider::ResponseWal.new(path("stream")).frames.to_a.fetch(0)
    expect(entry.request_digest).to eq(req.digest)
    expect(entry.bytes).to eq(sse)
    expect(entry).to be_complete
  end

  it "spools the raw HTTP response body of a non-streaming completion, before JSON parsing" do
    body = JSON.generate("id" => "msg_1", "model" => "claude-opus-4-8", "stop_reason" => "end_turn",
                         "content" => [{ "type" => "text", "text" => "hello" }],
                         "usage" => { "input_tokens" => 3, "output_tokens" => 2 })
    stub_messages(status: 200, body:, content_type: "application/json")
    spool = Lain::Provider::ResponseWal.new(path("sync"))
    provider = Lain::Provider::AnthropicRaw.new(spool:, api_key: "test")

    req = request(stream: false)
    response = provider.complete(req)
    spool.close

    expect(response.content.first["text"]).to eq("hello") # parsed body still reaches the caller
    entry = Lain::Provider::ResponseWal.new(path("sync")).frames.to_a.fetch(0)
    expect(entry.request_digest).to eq(req.digest)
    expect(entry.bytes).to eq(body) # verbatim wire bytes, not a re-serialization
    expect(entry).to be_complete
  end

  # The byte record must never lie: a salvage pass auto-commits complete frames,
  # so a retried attempt's bytes may never pass as one response. Frame-per-attempt
  # is the guarantee -- a retry aborts the frame underway and the retried attempt
  # gets its own, so the last COMPLETE frame per digest is the one true response.
  describe "under faraday-retry" do
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

    it "rotates to a new frame when a dropped stream is retried, leaving the aborted attempt inert" do
      sse = AnthropicSSE.body(canned)
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_raise(Faraday::ConnectionFailed)
        .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })
      spool = Lain::Provider::ResponseWal.new(path("stream-retry"))
      provider = Lain::Provider::AnthropicRaw.new(spool:, api_key: "test")

      req = request(stream: true)
      provider.complete(req)
      spool.close

      entries = Lain::Provider::ResponseWal.new(path("stream-retry")).frames.to_a
      expect(entries.map(&:request_digest)).to eq([req.digest, req.digest])
      expect(entries.first).not_to be_complete
      expect(entries.last.bytes).to eq(sse)
      expect(entries.last).to be_complete
    end

    it "wraps retry exhaustion in APIError and keeps the session's later frames readable" do
      sse = AnthropicSSE.body(canned)
      stub_request(:post, "https://api.anthropic.com/v1/messages").to_raise(Faraday::ConnectionFailed)
      spool = Lain::Provider::ResponseWal.new(path("exhaust"))
      provider = Lain::Provider::AnthropicRaw.new(spool:, api_key: "test")

      first = request(stream: true)
      # Nothing above the Provider rescues a transport class: exhaustion must
      # surface as the provider's own error, with the Faraday cause preserved.
      expect { provider.complete(first) }.to raise_error(Lain::Provider::AnthropicRaw::APIError) do |error|
        expect(error.cause).to be_a(Faraday::ConnectionFailed)
      end

      WebMock.reset!
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })
      second = request(stream: true, max_tokens: 65)
      provider.complete(second)
      spool.close

      entries = Lain::Provider::ResponseWal.new(path("exhaust")).frames.to_a
      expect(entries.select { |entry| entry.request_digest == first.digest }).to all(satisfy { |e| !e.complete? })
      survivor = entries.select(&:complete?)
      expect(survivor.map(&:request_digest)).to eq([second.digest])
      expect(survivor.first.bytes).to eq(sse)
    end

    # The terminal error rides the sync path: the vendored Anthropic STREAMING
    # error mapper coerces any non-overloaded error to a 500, which faraday-retry
    # then retries -- so a streamed 401 is not terminal (that case is the
    # exhaustion spec above). A sync 401 raises unretried, abandoning its frame.
    it "keeps later frames readable after a terminal (non-retried) error abandons its frame" do
      sse = AnthropicSSE.body(canned)
      error_body = JSON.generate("type" => "error",
                                 "error" => { "type" => "authentication_error", "message" => "no" })
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 401, body: error_body, headers: { "Content-Type" => "application/json" })
        .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })
      spool = Lain::Provider::ResponseWal.new(path("terminal"))
      provider = Lain::Provider::AnthropicRaw.new(spool:, api_key: "test")

      first = request(stream: false)
      expect { provider.complete(first) }.to raise_error(Lain::Provider::AnthropicRaw::APIStatusError)
      second = request(stream: true, max_tokens: 65)
      provider.complete(second)
      spool.close

      entries = Lain::Provider::ResponseWal.new(path("terminal")).frames.to_a
      expect(entries.select { |entry| entry.request_digest == first.digest }).to all(satisfy { |e| !e.complete? })
      survivor = entries.select(&:complete?)
      expect(survivor.map(&:request_digest)).to eq([second.digest])
      expect(survivor.first.bytes).to eq(sse)
    end

    it "keeps a retried sync completion clean: the failed attempt's error body never lands" do
      error_body = JSON.generate("type" => "error",
                                 "error" => { "type" => "rate_limit_error", "message" => "slow down" })
      success_body = JSON.generate("id" => "msg_1", "model" => "claude-opus-4-8", "stop_reason" => "end_turn",
                                   "content" => [{ "type" => "text", "text" => "ok" }],
                                   "usage" => { "input_tokens" => 1, "output_tokens" => 1 })
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 429, body: error_body, headers: { "Content-Type" => "application/json" })
        .to_return(status: 200, body: success_body, headers: { "Content-Type" => "application/json" })
      spool = Lain::Provider::ResponseWal.new(path("sync-retry"))
      provider = Lain::Provider::AnthropicRaw.new(spool:, api_key: "test")

      req = request(stream: false)
      provider.complete(req)
      spool.close

      entries = Lain::Provider::ResponseWal.new(path("sync-retry")).frames.to_a
      expect(entries.map(&:request_digest)).to eq([req.digest, req.digest])
      expect(entries.first).not_to be_complete
      expect(entries.first.bytes).not_to include("rate_limit_error")
      expect(entries.last.bytes).to eq(success_body)
      expect(entries.last).to be_complete
    end
  end

  it "is free when no spool is injected: no file is written and the response is unchanged" do
    body = JSON.generate("id" => "msg_1", "model" => "claude-opus-4-8", "stop_reason" => "end_turn",
                         "content" => [{ "type" => "text", "text" => "hello" }],
                         "usage" => { "input_tokens" => 3, "output_tokens" => 2 })
    stub_messages(status: 200, body:, content_type: "application/json")
    provider = Lain::Provider::AnthropicRaw.new(api_key: "test")

    response = provider.complete(request(stream: false))

    expect(response.content.first["text"]).to eq("hello")
    expect(Dir.glob(File.join(@dir, "*.wal"))).to be_empty
  end
end
