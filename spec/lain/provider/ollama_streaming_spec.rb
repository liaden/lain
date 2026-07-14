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
#      SDK-oracle differential AnthropicRaw leans on.
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
  def stream_transport(chunks)
    Class.new do
      define_method(:stream) { |_payload, _headers = {}, &block| chunks.each { |chunk| block.call(chunk) } }
    end.new
  end

  # A transport double returning a scripted single body (the non-streaming path).
  def transport_sync(body)
    Class.new do
      define_method(:sync_post) { |_payload, _headers = {}| Struct.new(:body).new(body) }
    end.new
  end

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

    it "derives :tool_use from the streamed tool_call despite done_reason stop" do
      response = described_class.new(transport: stream_transport([ndjson(stream_lines)]))
                                .complete(request(stream: true))
      expect(response.stop_reason).to eq(:tool_use)
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

      expect { described_class.new.complete(request(stream: true)) }.to raise_error(
        Lain::Provider::Ollama::APIStatusError
      ) { |error| expect(error.status).to eq(500) }
    end
  end
end
