# frozen_string_literal: true

# A response-log frame holds the bytes a provider teed off its own wire, so the
# frame is reassembled by the decoder of the provider that wrote it. Frames here
# are written by the real providers through a real ResponseWal wherever the
# bytes matter, so what is proved is that a recovered Response equals what the
# live call returned.
RSpec.describe Lain::Provider::Reassembly do
  around { |example| Dir.mktmpdir("reassembly") { |dir| @wal_path = File.join(dir, "session.wal") and example.run } }

  def wal = Lain::Provider::ResponseWal.new(@wal_path)
  def frame = wal.frames.to_a.last
  def text(body) = [{ "type" => "text", "text" => body }]

  let(:canned) do
    Lain::Response.new(id: "msg_1", model: "claude-opus-4-8", stop_reason: :end_turn,
                       content: text("recovered!"), usage: Lain::Usage.new(input_tokens: 10, output_tokens: 4))
  end

  def ollama_line(done:, **message)
    tail = done ? { "done_reason" => "stop", "prompt_eval_count" => 5, "eval_count" => 2 } : {}
    "#{JSON.generate({ "model" => "qwen3:4b", "message" => { "role" => "assistant" }.merge(message),
                       "done" => done }.merge(tail))}\n"
  end

  def ollama_request(stream: true)
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64, messages: [{ role: "user", content: "hi" }], stream:)
  end

  def spool_ollama(body, stream: true)
    content_type = stream ? "application/x-ndjson" : "application/json"
    stub_request(:post, %r{/api/chat}).to_return(status: 200, headers: { "Content-Type" => content_type }, body:)
    Lain::Provider::Ollama.new(config: zero_retry_config, spool: wal).complete(ollama_request(stream:))
  end

  def anthropic_request(stream: true)
    Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64, messages: [{ role: "user", content: "hi" }], stream:)
  end

  def spool_anthropic(body, stream: true)
    content_type = stream ? "text/event-stream" : "application/json"
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, body:, headers: { "Content-Type" => content_type })
    Lain::Provider::Anthropic.new(spool: wal, api_key: "test").complete(anthropic_request(stream:))
  end

  describe "an ollama frame" do
    let(:lines) do
      [ollama_line(done: false, "content" => "hello ", "thinking" => "hm"),
       ollama_line(done: true, "content" => "world")].join
    end

    it "reassembles a streamed frame into the thinking and text the live call returned" do
      live = spool_ollama(lines)

      response = described_class.call(frame, ceiling: 64)

      expect(response.content).to eq([{ "type" => "thinking", "thinking" => "hm" }, *text("hello world")])
      expect(response.content).to eq(live.content)
      expect(response.stop_reason).to eq(:end_turn)
    end

    # Pretty-printed, so a body routed to the NDJSON decoder by mistake would
    # fail line by line rather than parse as one line that happens to be whole.
    it "reassembles a non-streaming body the same way" do
      message = { "role" => "assistant", "content" => "hello world" }
      body = JSON.pretty_generate("model" => "qwen3:4b", "message" => message, "done" => true,
                                  "done_reason" => "stop", "prompt_eval_count" => 5, "eval_count" => 2)
      spool_ollama(body, stream: false)

      expect(frame.wire).to eq("ollama-json")
      expect(described_class.call(frame, ceiling: 64).content).to eq(text("hello world"))
    end

    # The bytes the QA reproduction wrote for an ollama-cloud session, which
    # salvage once committed as an empty assistant turn.
    it "recovers the cloud reproduction's frame with its content" do
      bytes = [%({"model":"m","message":{"role":"assistant","content":"hello "},"done":false}\n),
               %({"model":"m","message":{"role":"assistant","content":"world"},"done":true,"done_reason":"stop",),
               %("prompt_eval_count":5,"eval_count":2}\n)].join
      entry = Lain::Provider::ResponseWal::Entry.new(request_digest: "blake3:abc", bytes: bytes.b, complete: true,
                                                     wire: "ollama-ndjson")

      expect(described_class.call(entry, ceiling: nil).content).to eq(text("hello world"))
    end

    it "reads a reply that stopped short of the request's ceiling as a full window" do
      cut = "#{JSON.generate("model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "par" },
                             "done" => true, "done_reason" => "length", "eval_count" => 10)}\n"
      spool_ollama(cut)

      expect(described_class.call(frame, ceiling: 64).stop_reason).to eq(:context_full)
    end

    # The live decode journals a prose tool call; a reassembly has no session
    # record to write to and must not need one.
    it "decodes a prose tool call without a journal to write to" do
      prose = "<function=bash><parameter=command>ls</parameter></function>"
      spool_ollama(ollama_line(done: true, "content" => prose))

      response = described_class.call(frame, ceiling: 64)

      expect(response.malformed).to eq(:prose_tool_call)
      expect(response.stop_reason).to eq(:malformed)
    end
  end

  describe "an anthropic frame" do
    it "reassembles a streamed frame into the Response the shared wire decoder builds" do
      spool_anthropic(AnthropicSSE.body(canned))

      response = described_class.call(frame, ceiling: 64)

      expect(response.content).to eq(canned.content)
      expect(response.stop_reason).to eq(canned.stop_reason)
      expect(response.usage).to eq(canned.usage)
    end

    it "reassembles a non-streaming body" do
      body = JSON.generate("id" => "msg_1", "model" => "claude-opus-4-8", "stop_reason" => "end_turn",
                           "content" => text("recovered!"), "usage" => { "input_tokens" => 10, "output_tokens" => 4 })
      spool_anthropic(body, stream: false)

      response = described_class.call(frame, ceiling: 64)

      expect(frame.wire).to eq("anthropic-json")
      expect(response.content).to eq(text("recovered!"))
      expect(response.usage).to eq(Lain::Usage.new(input_tokens: 10, output_tokens: 4))
      expect(response.id).to eq("msg_1")
      expect(response.stop_reason).to eq(:end_turn)
    end
  end

  it "refuses a frame whose wire was never recorded, and says so" do
    entry = Lain::Provider::ResponseWal::Entry.new(request_digest: "d", bytes: "raw".b, complete: true, wire: nil)

    expect { described_class.call(entry, ceiling: nil) }
      .to raise_error(described_class::Unknown, /no wire was recorded/)
  end

  it "refuses a wire it has no decoder for" do
    entry = Lain::Provider::ResponseWal::Entry.new(request_digest: "d", bytes: "".b, complete: true,
                                                   wire: "carrier-pigeon")

    expect { described_class.call(entry, ceiling: nil) }.to raise_error(described_class::Unknown, /carrier-pigeon/)
  end
end
