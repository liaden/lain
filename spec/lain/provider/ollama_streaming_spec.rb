# frozen_string_literal: true

require "json"
require "webmock/rspec"

# T17: the NDJSON streaming path. Two empirical oracles:
#
#   1. Chunk boundaries cannot corrupt a line -- a canned NDJSON stream split at
#      deliberately awkward byte offsets (mid-line, mid-UTF-8-codepoint)
#      reassembles to the same body as the unsplit stream. This is the bug class
#      VCR cannot catch: a cassette replays one whole chunk, never the TCP-read
#      boundary that splits a line (or a multibyte char) in two.
#
#   2. Path parity -- the same canned exchange served as a stream and as a single
#      non-streaming body yields EQUAL Responses. This is the dry analogue of the
#      SDK-oracle differential Anthropic leans on.
RSpec.describe Lain::Provider::Ollama, "streaming" do
  def request(**overrides)
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  # A canned incremental exchange: text arrives in fragments, a tool_call lands
  # on its own line, the last line carries done + done_reason + counts. "café"
  # forces a multibyte codepoint into the content so a byte-offset split can land
  # mid-UTF-8.
  def stream_lines
    [
      { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "Hel" }, "done" => false },
      { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "lo, café" }, "done" => false },
      { "model" => "qwen3:4b",
        "message" => { "role" => "assistant", "content" => "",
                       "tool_calls" => [{ "function" => { "name" => "echo", "arguments" => { "text" => "hi" } } }] },
        "done" => false },
      { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "" },
        "done" => true, "done_reason" => "stop", "prompt_eval_count" => 11, "eval_count" => 7 }
    ]
  end

  # The single non-streaming body the same exchange collapses to.
  def single_body
    { "model" => "qwen3:4b",
      "message" => { "role" => "assistant", "content" => "Hello, café",
                     "tool_calls" => [{ "function" => { "name" => "echo", "arguments" => { "text" => "hi" } } }] },
      "done" => true, "done_reason" => "stop", "prompt_eval_count" => 11, "eval_count" => 7 }
  end

  def ndjson(lines)
    "#{lines.map { |line| JSON.generate(line) }.join("\n")}\n"
  end

  # Split a String into fixed-size BYTE chunks -- a size that does not divide the
  # multibyte "é" (2 bytes) or the newline framing lands a boundary mid-codepoint
  # and mid-line, exactly the TCP-read shapes a cassette hides.
  def byte_chunks(string, size)
    bytes = string.dup.force_encoding(Encoding::BINARY)
    (0...bytes.bytesize).step(size).map { |offset| bytes.byteslice(offset, size) }
  end

  # A transport double that replays scripted byte chunks through the on-chunk block.
  #
  # `attempt:` is DECLARED so a Provider that stopped threading it -- or threaded
  # it under a mistyped name -- fails loudly here. Ruby 3 hands a keyword to a
  # method accepting none back as a positional Hash, so an undeclared double
  # silently takes T2's `attempt:` as its HEADERS. See `ollama_spec.rb`'s
  # #transport_sync for the full note, including why the cop's suggested
  # `_attempt:` correction is the one thing that must not be applied.
  # rubocop:disable Lint/UnusedBlockArgument
  # `abandon_after:` makes this double do the one thing faraday-retry does that
  # matters to T10: abandon the round trip's attempt BETWEEN two chunks. Without
  # it the wiring that discards an abandoned attempt was pinned only by the
  # :seam examples at the bottom of this file -- and CLAUDE.md names
  # `--tag '~seam'` as the inner loop, so deleting the discard from
  # #stream_body was green across every non-seam example in spec/lain/provider/.
  # A developer running the loop the project recommends was told nothing.
  def stream_transport(chunks, abandon_after: nil)
    Class.new do
      define_method(:stream) do |_payload, _headers = {}, attempt: nil, &block|
        chunks.each_with_index do |chunk, index|
          block.call(chunk)
          attempt&.abandon if index == abandon_after
        end
      end
    end.new
  end

  # Like #stream_transport, but also captures the payload it was handed -- so a
  # think-enabled round trip can assert on the request body, not just the
  # decoded Response.
  def capturing_stream_transport(chunks)
    Class.new do
      attr_reader :payload

      define_method(:stream) do |payload, _headers = {}, attempt: nil, &block|
        @payload = payload
        chunks.each { |chunk| block.call(chunk) }
      end
    end.new
  end

  # A transport double returning a scripted single body (the non-streaming path).
  def transport_sync(body)
    Class.new do
      define_method(:sync_post) { |_payload, _headers = {}, attempt: nil| Struct.new(:body).new(body) }
    end.new
  end
  # rubocop:enable Lint/UnusedBlockArgument

  describe Lain::Provider::Ollama::StreamAssembler do
    def assemble(chunks)
      assembler = described_class.new
      chunks.each { |chunk| assembler.feed(chunk) }
      assembler.result
    end

    it "reassembles the same body whether fed whole or one byte at a time" do
      whole = ndjson(stream_lines)
      expect(assemble([whole])).to eq(assemble(byte_chunks(whole, 1)))
    end

    it "is immune to every byte-offset split, including mid-line and mid-UTF-8" do
      whole = ndjson(stream_lines)
      reference = assemble([whole])
      # Sizes that deliberately fall out of step with the 2-byte "é" and the
      # line framing, so boundaries land inside codepoints and inside JSON tokens.
      [2, 3, 5, 7, 13].each do |size|
        expect(assemble(byte_chunks(whole, size))).to eq(reference)
      end
    end

    it "concatenates content fragments in order and collects the tool_call" do
      body = assemble([ndjson(stream_lines)])
      expect(body["message"]["content"]).to eq("Hello, café")
      expect(body["message"]["tool_calls"].size).to eq(1)
      expect(body["done_reason"]).to eq("stop")
      expect(body["prompt_eval_count"]).to eq(11)
    end

    it "handles a final line that lacks a trailing newline" do
      whole = ndjson(stream_lines).chomp
      expect(assemble([whole])).to eq(assemble([ndjson(stream_lines)]))
    end

    # The lossless-record premise (CLAUDE.md: one stray line makes JSON.parse
    # fail) cuts both ways -- a torn line means the frame boundaries can no
    # longer be trusted, so the assembler raises rather than silently skipping.
    it "raises loudly on a corrupt NDJSON line mid-stream" do
      corrupt = "#{JSON.generate(stream_lines.first)}\n{not json at all}\n#{JSON.generate(stream_lines.last)}\n"
      expect { assemble([corrupt]) }.to raise_error(JSON::ParserError)
    end

    # T10. #reset is called once per RETRY, not once per round trip, so a
    # three-retry round trip calls it three times -- and it has to leave the
    # assembler USABLE each time, not merely emptied once. The seam examples at
    # the bottom of this file prove that indirectly (a four-connection round
    # trip cannot record four requests unless the assembler kept accepting
    # chunks across three discards); these say it directly.
    describe "#reset, the discard a retry drives" do
      it "assembles the surviving attempt alone, however many were discarded" do
        reference = assemble([ndjson(stream_lines)])
        assembler = described_class.new
        3.times do
          assembler.feed(ndjson(stream_lines.first(2)))
          assembler.reset
        end
        assembler.feed(ndjson(stream_lines))

        expect(assembler.result).to eq(reference)
      end

      it "is harmless before anything has been fed" do
        assembler = described_class.new
        3.times { assembler.reset }
        assembler.feed(ndjson(stream_lines))

        expect(assembler.result).to eq(assemble([ndjson(stream_lines)]))
      end

      # The subtle half, and the one the buffer's scan cursor is about: a
      # severed attempt usually dies MID-LINE, so the discard has to take the
      # partial bytes and `@scanned` with it. A surviving half-line would be
      # prefixed onto the retry's first line -- still a splice, just one that
      # fails loudly on JSON::ParserError instead of quietly, which is not a fix.
      it "discards a half-delivered line rather than prefixing it onto the retry" do
        whole = ndjson(stream_lines)
        partial = whole.byteslice(0, 25)
        # The offset is only interesting if it lands MID-LINE, and nothing else
        # here holds it there -- the first line is 80 bytes today, so 55 bytes of
        # slack would disappear silently if #stream_lines ever shortened.
        expect(partial).not_to include("\n")

        assembler = described_class.new
        assembler.feed(partial)
        assembler.reset
        assembler.feed(whole)

        expect(assembler.result).to eq(assemble([whole]))
      end

      # Every other example here ends its SURVIVING attempt with a done line,
      # which overwrites the metadata and hides a reset that clears only the
      # prose -- measured: dropping @model/@done_reason/@prompt_eval_count/
      # @eval_count from #reset passed all of them. The uncovered shape is this
      # card's own corruption one field over: an attempt that reached its `done`
      # line before the RST, replaced by one that has not finished, reports the
      # DISCARDED attempt's done_reason and token counts as the survivor's.
      it "discards the done line's metadata, not only the accumulated prose" do
        assembler = described_class.new
        assembler.feed(ndjson(stream_lines))
        assembler.reset
        # A line with no `model` key, so a surviving @model cannot be masked by
        # the replacement setting it again.
        assembler.feed(ndjson([{ "message" => { "role" => "assistant", "content" => "x" }, "done" => false }]))
        body = assembler.result

        expect(body["eval_count"]).to be_nil
        expect(body["prompt_eval_count"]).to be_nil
        expect(body["done_reason"]).to be_nil
        expect(body["model"]).to be_nil
        expect(body["message"]["content"]).to eq("x")
      end
    end
  end

  describe "#complete on the streaming path" do
    it "declares the :streaming capability now that the path exists" do
      provider = described_class.new(transport: transport_sync(single_body))
      expect(provider.capabilities).to include(:streaming)
      expect(provider.capabilities - Lain::Provider::CAPABILITIES).to be_empty
    end

    # AC 2: path parity -- the acceptance oracle.
    it "yields a Response equal to the non-streaming path for the same exchange" do
      streamed = described_class.new(transport: stream_transport(byte_chunks(ndjson(stream_lines), 4)))
                                .complete(request(stream: true))
      synchronous = described_class.new(transport: transport_sync(single_body))
                                   .complete(request(stream: false))

      expect(streamed.content).to eq(synchronous.content)
      expect(streamed.stop_reason).to eq(synchronous.stop_reason)
      expect(streamed.usage).to eq(synchronous.usage)
    end

    # AC 1, at the provider seam: an awkward split cannot corrupt the Response.
    it "produces the same Response no matter how the stream is chunked" do
      one_shot = described_class.new(transport: stream_transport([ndjson(stream_lines)]))
                                .complete(request(stream: true))
      shredded = described_class.new(transport: stream_transport(byte_chunks(ndjson(stream_lines), 1)))
                                .complete(request(stream: true))

      expect(shredded.content).to eq(one_shot.content)
      expect(shredded.stop_reason).to eq(one_shot.stop_reason)
      expect(shredded.usage).to eq(one_shot.usage)
    end

    # The wiring guarantee at the UNIT tier, so the inner loop covers it: the
    # transport double abandons this round trip's attempt between the two
    # chunks, exactly as faraday-retry does on a retry, and the first chunk's
    # content must not survive into the Response. Deleting the `{ assembler.reset }`
    # block from #stream_body turns this red without a socket.
    it "discards what was fed before the transport abandoned the attempt" do
      chunks = [ndjson([stream_lines.first]), ndjson(stream_lines)]

      response = described_class.new(transport: stream_transport(chunks, abandon_after: 0))
                                .complete(request(stream: true))

      expect(response.text).to eq("Hello, café")
    end

    it "derives :tool_use from the streamed tool_call despite done_reason stop" do
      response = described_class.new(transport: stream_transport([ndjson(stream_lines)]))
                                .complete(request(stream: true))
      expect(response).to stop_with(:tool_use)
      expect(response.tool_uses.first["input"]).to eq({ "text" => "hi" })
    end

    # The provider seam wraps the assembler's bare JSON::ParserError into the
    # same APIError family transport errors wear, original on #cause -- callers
    # rescue one provider-error family, and the failure stays loud.
    it "wraps a corrupt NDJSON line in APIError with the parse error as cause" do
      corrupt = "{not json at all}\n"
      provider = described_class.new(transport: stream_transport([corrupt]))
      expect { provider.complete(request(stream: true)) }.to raise_error(
        Lain::Provider::Ollama::APIError, /corrupt NDJSON line/
      ) { |error| expect(error.cause).to be_a(JSON::ParserError) }
    end

    # AC: think round-trips, on the NDJSON path. Ollama interleaves `thinking`
    # chunks before `content` chunks (references/ollama/api-chat.md); the
    # StreamAssembler already buffers both until `done` (stream_assembler.rb),
    # so this is the encode half (think:true reaches the wire) exercised
    # together with that existing decode half.
    it "sends think:true and reassembles a thinking block matching the Anthropic shape" do
      think_lines = [
        { "model" => "qwen3:4b", "message" => { "role" => "assistant", "thinking" => "let me " }, "done" => false },
        { "model" => "qwen3:4b", "message" => { "role" => "assistant", "thinking" => "think" }, "done" => false },
        { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "42" }, "done" => false },
        { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "" },
          "done" => true, "done_reason" => "stop", "prompt_eval_count" => 5, "eval_count" => 3 }
      ]
      transport = capturing_stream_transport([ndjson(think_lines)])

      response = described_class.new(transport:).complete(request(stream: true, extra: { think: true }))

      expect(transport.payload[:think]).to be(true)
      expect(response.blocks_of_type("thinking")).to eq([{ "type" => "thinking", "thinking" => "let me think" }])
      expect(response.text).to eq("42")
    end
  end

  # The real Faraday transport, exercised once over WebMock so the URL, the
  # stream:true payload, and the raw x-ndjson chunk feeding are pinned end-to-end,
  # not just the injected double.
  describe "over the real transport", :webmock do
    it "posts stream:true to /api/chat and reassembles the x-ndjson body" do
      stub = stub_request(:post, "http://localhost:11434/api/chat")
             .with { |req| JSON.parse(req.body)["stream"] == true }
             .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                        body: ndjson(stream_lines))

      response = described_class.new.complete(request(stream: true))

      expect(response.text).to eq("Hello, café")
      expect(response.tool_uses.size).to eq(1)
      expect(stub).to have_been_requested
    end

    # The streaming error arm: a non-2xx stream routes through the vendored
    # failed-response handling and surfaces as the SAME typed error the sync
    # path wraps -- nothing above the Provider sees a Provider::HTTP class.
    it "wraps a 500 mid-stream into APIStatusError with the status lifted out" do
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("error" => "model runner has unexpectedly stopped"))

      expect { described_class.new(config: zero_retry_config).complete(request(stream: true)) }.to raise_error(
        Lain::Provider::Ollama::APIStatusError
      ) { |error| expect(error.status).to eq(500) }
    end
  end

  # T38. What a human types wrong, and what they are told about it. Chat streams
  # by default, so these are THE error messages for this arm -- and asserting the
  # class alone (as the example above does) passed while every one of them read
  # "An unknown error occurred".
  #
  # Faraday hands a streamed body to `on_data` and leaves `env.body` empty, so
  # the error {Provider::HTTP::ErrorMiddleware} raises on the way out has nothing
  # to quote. The bodies below are REAL ollama answers, taken off a live server
  # on localhost:11434 (2026-08-05, ollama 0.32.1) -- the 500 is the one this
  # file already canned.
  describe "the message a failed stream reports", :webmock do
    def stub_chat(status, error)
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status:, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("error" => error))
    end

    def failure(status, error, stream: true)
      stub_chat(status, error)
      described_class.new(config: zero_retry_config).complete(request(stream:))
      raise "expected a failure"
    rescue Lain::Provider::Ollama::APIStatusError => e
      e
    end

    # `lain chat --provider ollama --model no-such-model-xyz`, verbatim.
    it "names the model ollama could not find, on a 404" do
      error = failure(404, "model 'no-such-model-xyz' not found")

      expect(error.message).to eq("model 'no-such-model-xyz' not found")
      expect(error.status).to eq(404)
    end

    # The second real shape: ollama answers 400 to a request with no model.
    it "names a 400 refusal in ollama's own words" do
      error = failure(400, "model is required")

      expect(error.message).to eq("model is required")
      expect(error.status).to eq(400)
    end

    # The retryable shape. The message has to survive the retry loop, which is
    # where it was being destroyed: faraday-retry replays the attempt through
    # the same `on_data` handler.
    it "keeps the message across an exhausted retry loop, on a 500" do
      error = failure(500, "model runner has unexpectedly stopped")

      expect(error.message).to eq("model runner has unexpectedly stopped")
      expect(error.status).to eq(500)
    end

    # The acceptance oracle, and the one that cannot be gamed: a human must not
    # be able to tell which path the request took from what they are told.
    it "reports exactly what the same failure reports on the non-streaming path" do
      streamed = failure(404, "model 'no-such-model-xyz' not found")
      WebMock.reset!
      synchronous = failure(404, "model 'no-such-model-xyz' not found", stream: false)

      expect([streamed.message, streamed.status]).to eq([synchronous.message, synchronous.status])
    end

    # A 404 is not retryable and the sync path never retries one; relabeling it
    # 500 to carry a nicer message would be RES1 again (anthropic/transport.rb),
    # and it costs four round trips to a server that already said no.
    it "does not retry a 404, exactly as the non-streaming path does not" do
      stub = stub_chat(404, "model 'no-such-model-xyz' not found")

      expect { described_class.new(config: zero_retry_config).complete(request(stream: true)) }
        .to raise_error(Lain::Provider::Ollama::APIStatusError)
      expect(stub).to have_been_requested.times(1)
    end

    # ... while a 500 still exhausts the loop. The message must not be bought
    # by turning the retry policy off.
    it "still retries a 500 the full three times" do
      stub = stub_chat(500, "model runner has unexpectedly stopped")

      expect { described_class.new(config: zero_retry_config).complete(request(stream: true)) }
        .to raise_error(Lain::Provider::Ollama::APIStatusError)
      expect(stub).to have_been_requested.times(4)
    end

    # One Provider holds ONE Transport for its whole life, so a body kept
    # anywhere longer than a request would make a later failure report an
    # earlier one -- a lie that reads exactly like a correct answer.
    it "never reports an earlier request's message on a later one" do
      provider = described_class.new(config: zero_retry_config)
      stub_chat(404, "model 'gone-away' not found")
      expect { provider.complete(request(stream: true)) }.to raise_error(/gone-away/)

      WebMock.reset!
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 404, headers: { "Content-Type" => "application/json" }, body: "")

      expect { provider.complete(request(stream: true)) }.to raise_error(
        Lain::Provider::Ollama::APIStatusError
      ) { |error| expect(error.message).not_to include("gone-away") }
    end
  end

  # T10/F7b -- measured silent corruption of a content-addressed record, not an
  # inferred one. #stream_body built its assembler OUTSIDE @transport.stream
  # while faraday-retry lives INSIDE it, so a severed attempt's bytes stayed in
  # the assembler and the retry appended to them: a completion came back `ok`,
  # under a done_reason of "stop", carrying BOTH attempts' text spliced
  # together. Nothing above the Provider could tell.
  #
  # This is reachable from exactly one instrument. WebMock hands a stubbed body
  # over as ONE chunk and, on a connection severed mid-body, loses the bytes
  # that did arrive inside its own read -- which is the limitation
  # spec/lain/provider/ollama/streamed_failure_spec.rb:5-9 named years before
  # anyone chased it, listing "the same handler being replayed by faraday-retry"
  # as one of two shapes it cannot express. So these drive a real socket through
  # T1's StreamingUpstream. An assertion here that passed under WebMock would
  # not be testing this defect.
  #
  # NOT tagged :vcr, and never inside VCR.use_cassette: a replaying cassette
  # makes NetworkAccess.permit_loopback inert and the refusal names neither the
  # port nor the cassette.
  #
  # Ollama's NDJSON carries no `message_start`-equivalent for an assembler to
  # re-sync on -- which is why the Anthropic path survives the simple case and
  # this one does not -- so the discard has to be driven by the retry hook.
  # {RetryTap::Attempt} is that hook, and the invariant it states is the one
  # under test: a retried attempt must never share a frame with the one it
  # replaced.
  describe "a stream the transport retries", :seam do
    # Immutable, so one instance refines per example without leaking.
    let(:script) { StreamingUpstream.script }
    let(:wire) { StreamingUpstream::Wire }

    # The envelope must be shaped BEFORE construction (spec/support/zero_retry.rb):
    # MiddlewareStack snapshots interval, factor and max when the transport is
    # built, so pointing an already-built provider at the upstream would retry
    # on the production schedule and blow the 30s watchdog.
    def provider_for(upstream)
      described_class.new(config: zero_retry_config.tap { |config| config.ollama_api_base = upstream.url })
    end

    # AC 1. The defect itself: attempt one lands two content fragments and dies
    # on a hard RST (a RST does not destroy what is already in the client's
    # receive queue -- measured 60/60 in the harness -- so those fragments
    # really do reach the assembler), then the retry serves a complete stream.
    # Only the retry's content may survive.
    it "returns only the retry's content, never the abandoned attempt's" do
      response = nil
      connections = nil

      StreamingUpstream.ndjson(
        script.chunks(wire.ollama_content("PARTIAL-alpha"), wire.ollama_content("PARTIAL-beta")).sever,
        script.chunks(wire.ollama_content("RETRY-one"), wire.ollama_done(text_response(""))).close
      ) do |upstream|
        response = provider_for(upstream).complete(request(stream: true))
        # `upstream.requests`, never assert_requested: a bypassed request is
        # invisible to WebMock's bookkeeping by design.
        connections = upstream.requests.size
      end

      expect(connections).to eq(2)
      expect(response.text).to eq("RETRY-one")
      expect(response).to stop_with(:end_turn)
    end

    # The discard must not be offerable. `journaled_retries` wired the tap with
    # `||=`, which was correct policy while the block carried only telemetry --
    # and `ollama_spec.rb` already ships a config with its own `retry_block`, so
    # the bypass was not hypothetical. Measured on this exact script before the
    # composition fix: text came back "PARTIAL-alphaPARTIAL-betaRETRY-one" under
    # `:end_turn` -- the entire F7b defect, reinstated by a documented seam. The
    # caller's callback must still fire, or the fix is just a removal.
    it "still discards the abandoned attempt when the config brings its own retry_block" do
      response = nil
      counted = []

      StreamingUpstream.ndjson(
        script.chunks(wire.ollama_content("PARTIAL-alpha"), wire.ollama_content("PARTIAL-beta")).sever,
        script.chunks(wire.ollama_content("RETRY-one"), wire.ollama_done(text_response(""))).close
      ) do |upstream|
        config = zero_retry_config.tap { |settings| settings.ollama_api_base = upstream.url }
        config.retry_block = ->(retry_count:, **) { counted << retry_count }
        response = described_class.new(config:).complete(request(stream: true))
      end

      expect(response.text).to eq("RETRY-one")
      expect(response).to stop_with(:end_turn)
      expect(counted).to eq([0])
    end

    # AC 2. The control. A reset driven by the retry hook must be dead weight on
    # the path that never retries -- if this went red, the fix would be
    # discarding live bytes rather than abandoned ones.
    it "leaves a stream that is never retried exactly as it was served" do
      response = nil
      connections = nil

      StreamingUpstream.ndjson(
        script.chunks(wire.ollama_content("ONLY-one"), wire.ollama_content("ONLY-two"),
                      wire.ollama_done(text_response(""))).close
      ) do |upstream|
        response = provider_for(upstream).complete(request(stream: true))
        connections = upstream.requests.size
      end

      expect(connections).to eq(1)
      expect(response.text).to eq("ONLY-oneONLY-two")
      expect(response).to stop_with(:end_turn)
    end

    # AC 3, and it asserts on the RAISE rather than on a reset, deliberately.
    # `exhausted_retries_block` journals and does NOT abandon, so the last
    # attempt's bytes are still in the assembler when the budget runs out; what
    # makes them unreturnable is that #stream_body never reaches `result`. One
    # script severs every connection -- the last one repeats forever once the
    # queue drains, so "severs every attempt" is one script, not four.
    it "raises rather than returning what the severed attempts accumulated" do
      connections = nil

      StreamingUpstream.ndjson(
        script.chunks(wire.ollama_content("PARTIAL-alpha"), wire.ollama_content("PARTIAL-beta")).sever
      ) do |upstream|
        provider = provider_for(upstream)

        expect { provider.complete(request(stream: true)) }
          .to raise_error(Lain::Provider::Ollama::APIError)
        connections = upstream.requests.size
      end

      expect(connections).to eq(4)
    end
  end
end
