# frozen_string_literal: true

# The assembler is the "stop flattening" mutation, tested where the flattening
# used to live. These assertions are exactly what the vendored StreamAccumulator
# CANNOT satisfy: every block survives in order, and every thinking signature
# survives -- not just the first.
RSpec.describe Lain::Provider::AnthropicRaw::StreamAssembler do
  # Feed a full, ordered turn one event at a time, the way the transport does.
  def feed(assembler, events)
    events.each { |event| assembler.add(event) }
    assembler.result
  end

  def message_start(usage: { "input_tokens" => 10, "output_tokens" => 0 })
    { "type" => "message_start",
      "message" => { "id" => "msg_1", "model" => "claude-opus-4-8", "usage" => usage } }
  end

  it "retains every block in wire order -- thinking, text, and tool_use" do
    result = feed(described_class.new, [
                    message_start,
                    { "type" => "content_block_start", "index" => 0,
                      "content_block" => { "type" => "thinking", "thinking" => "" } },
                    { "type" => "content_block_delta", "index" => 0,
                      "delta" => { "type" => "thinking_delta", "thinking" => "let me look" } },
                    { "type" => "content_block_delta", "index" => 0,
                      "delta" => { "type" => "signature_delta", "signature" => "sig-A" } },
                    { "type" => "content_block_stop", "index" => 0 },
                    { "type" => "content_block_start", "index" => 1,
                      "content_block" => { "type" => "text", "text" => "" } },
                    { "type" => "content_block_delta", "index" => 1,
                      "delta" => { "type" => "text_delta", "text" => "reading" } },
                    { "type" => "content_block_stop", "index" => 1 },
                    { "type" => "content_block_start", "index" => 2,
                      "content_block" => { "type" => "tool_use", "id" => "tu_1", "name" => "read_file",
                                           "input" => {} } },
                    { "type" => "content_block_delta", "index" => 2,
                      "delta" => { "type" => "input_json_delta", "partial_json" => '{"path":"x.rb"}' } },
                    { "type" => "content_block_stop", "index" => 2 },
                    { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" },
                      "usage" => { "output_tokens" => 42 } }
                  ])

    expect(result.content.map { |block| block["type"] }).to eq(%w[thinking text tool_use])
    expect(result.stop_reason).to eq("tool_use")
  end

  # The headline of Step A: the vendored accumulator keeps only the FIRST
  # thinking signature. This one must keep both.
  it "keeps a second thinking block's signature rather than dropping it" do
    result = feed(described_class.new, [
                    message_start,
                    { "type" => "content_block_start", "index" => 0,
                      "content_block" => { "type" => "thinking", "thinking" => "one" } },
                    { "type" => "content_block_delta", "index" => 0,
                      "delta" => { "type" => "signature_delta", "signature" => "sig-A" } },
                    { "type" => "content_block_stop", "index" => 0 },
                    { "type" => "content_block_start", "index" => 1,
                      "content_block" => { "type" => "thinking", "thinking" => "two" } },
                    { "type" => "content_block_delta", "index" => 1,
                      "delta" => { "type" => "signature_delta", "signature" => "sig-B" } },
                    { "type" => "content_block_stop", "index" => 1 },
                    { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" }, "usage" => {} }
                  ])

    signatures = result.content.select { |block| block["type"] == "thinking" }.map { |block| block["signature"] }
    expect(signatures).to eq(%w[sig-A sig-B])
  end

  it "reassembles an input_json_delta split at an awkward byte offset and parses it once" do
    result = feed(described_class.new, [
                    message_start,
                    { "type" => "content_block_start", "index" => 0,
                      "content_block" => { "type" => "tool_use", "id" => "tu_1", "name" => "grep",
                                           "input" => {} } },
                    # Split mid-token: the first fragment ends inside the value string.
                    { "type" => "content_block_delta", "index" => 0,
                      "delta" => { "type" => "input_json_delta", "partial_json" => '{"pattern":"foo' } },
                    { "type" => "content_block_delta", "index" => 0,
                      "delta" => { "type" => "input_json_delta", "partial_json" => 'bar","n":3}' } },
                    { "type" => "content_block_stop", "index" => 0 },
                    { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" }, "usage" => {} }
                  ])

    input = result.content.first["input"]
    expect(input).to eq("pattern" => "foobar", "n" => 3)
    expect(input).to be_a(Hash)
  end

  it "treats an empty argument buffer as an empty object" do
    result = feed(described_class.new, [
                    message_start,
                    { "type" => "content_block_start", "index" => 0,
                      "content_block" => { "type" => "tool_use", "id" => "tu_1", "name" => "now", "input" => {} } },
                    { "type" => "content_block_stop", "index" => 0 },
                    { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" }, "usage" => {} }
                  ])

    expect(result.content.first["input"]).to eq({})
  end

  it "carries id, model, and merged usage through from start to delta" do
    result = feed(described_class.new, [
                    message_start(usage: { "input_tokens" => 100, "cache_read_input_tokens" => 40,
                                           "output_tokens" => 1 }),
                    { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
                      "usage" => { "output_tokens" => 25 } }
                  ])

    expect(result.id).to eq("msg_1")
    expect(result.model).to eq("claude-opus-4-8")
    expect(result.usage).to include("input_tokens" => 100, "cache_read_input_tokens" => 40, "output_tokens" => 25)
  end
end
