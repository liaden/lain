# frozen_string_literal: true

# The assembler is the "stop flattening" mutation, tested where the flattening
# used to live. These assertions are exactly what the vendored StreamAccumulator
# CANNOT satisfy: every block survives in order, and every thinking signature
# survives -- not just the first.
RSpec.describe Lain::Provider::Anthropic::StreamAssembler do
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
    expect(result).to stop_with("tool_use")
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

  # T11 / F7c. One assembler serves a whole round trip, not one attempt: the
  # Provider builds it once and faraday-retry replays through the same block, so
  # a retry's events land on top of whatever the abandoned attempt left behind.
  # `message_start` is the marker that says a new message began -- Anthropic
  # opens every one with exactly one, which is the re-sync Ollama's NDJSON has no
  # equivalent of (see Ollama::RetryTap).
  describe "a second message_start, which is a retry" do
    def retried(second_attempt) = feed(described_class.new, abandoned_events + second_attempt)

    # What faraday-retry threw away: a text block it closed, and a tool_use it
    # had opened and begun filling when the connection died. Index 1 is the one
    # the retry never reopens, so nothing overwrites it.
    let(:abandoned_events) do
      [message_start,
       { "type" => "content_block_start", "index" => 0,
         "content_block" => { "type" => "text", "text" => "" } },
       { "type" => "content_block_delta", "index" => 0,
         "delta" => { "type" => "text_delta", "text" => "partial prose" } },
       { "type" => "content_block_stop", "index" => 0 },
       { "type" => "content_block_start", "index" => 1,
         "content_block" => { "type" => "tool_use", "id" => "toolu_orphan", "name" => "echo", "input" => {} } },
       { "type" => "content_block_delta", "index" => 1,
         "delta" => { "type" => "input_json_delta", "partial_json" => '{"text":"hi"}' } }]
    end

    let(:retry_events) do
      [message_start(usage: { "input_tokens" => 10, "output_tokens" => 0 }),
       { "type" => "content_block_start", "index" => 0,
         "content_block" => { "type" => "text", "text" => "" } },
       { "type" => "content_block_delta", "index" => 0,
         "delta" => { "type" => "text_delta", "text" => "the retry" } },
       { "type" => "content_block_stop", "index" => 0 },
       { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
         "usage" => { "output_tokens" => 3 } }]
    end

    it "drops a block index the retry never reopens" do
      result = retried(retry_events)

      expect(result.content.map { |block| block["type"] }).to eq(%w[text])
      expect(result.content.first["text"]).to eq("the retry")
    end

    # The form that matters: the abandoned attempt had reached a tool_use, so
    # what survived was a call the model never finished asking for -- reported
    # under a clean `end_turn`.
    it "drops a half-built tool_use rather than leaving a phantom call" do
      result = retried(retry_events)

      expect(result.content.map { |block| block["id"] }).not_to include("toolu_orphan")
      expect(result).to stop_with("end_turn")
    end

    # The input buffer goes with the block. A stop for an index the reset
    # discarded must be inert, not a NoMethodError on a block that is gone.
    it "discards the abandoned attempt's input buffer with its block" do
      result = retried(retry_events + [{ "type" => "content_block_stop", "index" => 1 }])

      expect(result.content.size).to eq(1)
    end

    # The envelope is re-read from the new message_start, so a retry that came
    # back on a different model or message id is described by its own numbers.
    it "re-seeds id, model, and usage from the message that replaced it" do
      result = retried([{ "type" => "message_start",
                          "message" => { "id" => "msg_2", "model" => "claude-opus-4-9",
                                         "usage" => { "input_tokens" => 7 } } }])

      expect([result.id, result.model]).to eq(["msg_2", "claude-opus-4-9"])
      expect(result.usage).to eq("input_tokens" => 7)
    end

    # `@stop_reason` is the discarded field with no other witness, and it is not
    # decorative: {#on_message_delta} reads `... || @stop_reason`, so a reason the
    # ABANDONED attempt reported survives whenever the replacement ends WITHOUT a
    # message_delta of its own -- the retry's content under the dead attempt's
    # envelope, which is this card's own defect one layer up. Mutation-checked
    # during review: dropping that one line from #discard_attempt failed nothing
    # else in the suite.
    it "clears a stop_reason the abandoned attempt had already reported" do
      reported = { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" },
                   "usage" => { "output_tokens" => 9 } }
      # The replacement delivers content and closes cleanly, but never sends a
      # message_delta -- so nothing overwrites what `reported` left behind.
      truncated = [message_start,
                   { "type" => "content_block_start", "index" => 0,
                     "content_block" => { "type" => "text", "text" => "" } },
                   { "type" => "content_block_delta", "index" => 0,
                     "delta" => { "type" => "text_delta", "text" => "the retry" } },
                   { "type" => "content_block_stop", "index" => 0 }]

      result = retried([reported] + truncated)

      expect(result.stop_reason).to be_nil
      expect(result.content.map { |block| block["type"] }).to eq(%w[text])
    end
  end

  # The reset must not be mistaken for "flush on every event": within ONE attempt
  # a block accumulates across arbitrarily many `add` calls, which is the
  # streaming invariant the transport depends on.
  it "keeps appending to an open block across arbitrarily many add calls" do
    fragments = Array.new(64) { |n| n.to_s(16) }
    deltas = fragments.map do |text|
      { "type" => "content_block_delta", "index" => 0, "delta" => { "type" => "text_delta", "text" => text } }
    end
    opening = [message_start,
               { "type" => "content_block_start", "index" => 0,
                 "content_block" => { "type" => "text", "text" => "" } }]
    closing = [{ "type" => "content_block_stop", "index" => 0 },
               { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" }, "usage" => {} }]

    result = feed(described_class.new, opening + deltas + closing)

    expect(result.content.first["text"]).to eq(fragments.join)
  end
end
