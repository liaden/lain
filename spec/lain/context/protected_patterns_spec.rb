# frozen_string_literal: true

RSpec.describe Lain::Context::ProtectedPatterns do
  describe "#protects?" do
    it "matches a literal String pattern as a substring" do
      patterns = described_class.new(["do-not-drop"])
      expect(patterns.protects?("keep this do-not-drop span")).to be(true)
      expect(patterns.protects?("nothing special here")).to be(false)
    end

    it "matches a Regexp pattern" do
      patterns = described_class.new([/critical-\d+/])
      expect(patterns.protects?("ticket critical-42 must survive")).to be(true)
      expect(patterns.protects?("ticket ordinary-42")).to be(false)
    end

    it "matches if ANY configured pattern hits" do
      patterns = described_class.new(%w[alpha beta])
      expect(patterns.protects?("contains beta")).to be(true)
    end
  end

  describe "#none?" do
    it "is true for the default empty policy" do
      expect(described_class.new.none?).to be(true)
    end

    it "is false once any pattern is configured" do
      expect(described_class.new(["x"]).none?).to be(false)
    end
  end

  describe "::NONE" do
    it "protects nothing -- the no-op default every consumer inherits" do
      expect(described_class::NONE.protects?("anything at all")).to be(false)
      expect(described_class::NONE.none?).to be(true)
    end
  end

  # AC3: a span matching a protected pattern is exempt in EVERY consumer --
  # DedupeToolCalls, PurgeFailedInputs, Prune, and Compact all take the SAME
  # ProtectedPatterns value and none of them may drop a matching span.
  describe "exempt in every consumer" do
    let(:pattern) { described_class.new([/keep-me/]) }

    def text(body) = [{ "type" => "text", "text" => body }]
    def message(role, body) = { "role" => role, "content" => text(body) }

    def tool_use(id:, name:, input:)
      { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
    end

    def tool_result(id:, content:, is_error: false)
      { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
    end

    it "DedupeToolCalls never drops a protected duplicate" do
      messages = [
        { "role" => "assistant", "content" => [tool_use(id: "a1", name: "search", input: { "q" => "keep-me" })] },
        { "role" => "user", "content" => [tool_result(id: "a1", content: "first")] },
        { "role" => "assistant", "content" => [tool_use(id: "a2", name: "search", input: { "q" => "keep-me" })] },
        { "role" => "user", "content" => [tool_result(id: "a2", content: "second")] }
      ]

      result = Lain::Context::DedupeToolCalls.new(protected_patterns: pattern).call(messages)

      expect(result).to eq(messages)
    end

    it "PurgeFailedInputs never redacts a protected input" do
      messages = [
        { "role" => "assistant", "content" => [tool_use(id: "b1", name: "search", input: { "q" => "keep-me" })] },
        { "role" => "user", "content" => [tool_result(id: "b1", content: "boom", is_error: true)] },
        message("assistant", "filler one"),
        message("assistant", "filler two")
      ]

      result = Lain::Context::PurgeFailedInputs.new(turns: 1, protected_patterns: pattern).call(messages)

      expect(result.first["content"].first["input"]).to eq({ "q" => "keep-me" })
    end

    it "Prune never drops a protected message under keep_last:" do
      messages = [message("user", "keep-me please"), message("user", "one"), message("user", "two")]

      result = Lain::Context::Prune.new(keep_last: 1, protected_patterns: pattern).call(messages)

      expect(result).to include(messages.first)
    end

    it "Prune never drops a protected message under a predicate" do
      messages = [message("user", "keep-me please"), message("assistant", "one")]

      result = Lain::Context::Prune.new(protected_patterns: pattern) { |m| m["role"] == "assistant" }.call(messages)

      expect(result).to include(messages.first)
    end

    it "Compact never summarizes away a protected message" do
      messages = [
        message("user", "keep-me #{"a" * 200}"),
        message("assistant", "b" * 200),
        message("user", "c" * 200),
        message("assistant", "d" * 200)
      ]
      summarizer = ->(dropped) { "summary of #{dropped.size} turns" }

      result = Lain::Context::Compact.new(threshold: 10, keep_last: 1, summarizer:, protected_patterns: pattern)
                                     .call(messages)

      expect(result).to include(messages.first)
    end
  end

  # Granularity must be UNIFORM across all four consumers: "a protected span
  # is never dropped" (AC3) reads as one concept, not "protected block" for
  # two consumers and "protected message" for the other two. Every consumer
  # checks the CONTAINING MESSAGE's Canonical.dump, never a narrower block --
  # so the protecting text can live ANYWHERE in the message (a sibling text
  # block, not just inside the specific tool_use/tool_result under
  # consideration) and the whole message's spans still survive.
  describe "protection is message-granular, uniformly, across every consumer" do
    let(:pattern) { described_class.new([/SAME-PROTECTED-SPAN/]) }

    def tool_use(id:, name:, input:)
      { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
    end

    def tool_result(id:, content:, is_error: false)
      { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
    end

    def sibling_text = { "type" => "text", "text" => "note: SAME-PROTECTED-SPAN" }

    it "DedupeToolCalls protects a stale tool_use whose CONTAINING MESSAGE carries the span " \
       "even though the tool_use's own input does not" do
      messages = [
        {
          "role" => "assistant",
          "content" => [sibling_text, tool_use(id: "a1", name: "search", input: { "q" => "ordinary" })]
        },
        { "role" => "user", "content" => [tool_result(id: "a1", content: "first")] },
        { "role" => "assistant", "content" => [tool_use(id: "a2", name: "search", input: { "q" => "ordinary" })] },
        { "role" => "user", "content" => [tool_result(id: "a2", content: "second")] }
      ]

      result = Lain::Context::DedupeToolCalls.new(protected_patterns: pattern).call(messages)

      expect(result).to eq(messages)
    end

    it "PurgeFailedInputs protects a failed tool_use whose CONTAINING MESSAGE carries the span " \
       "even though the tool_use's own input does not" do
      messages = [
        {
          "role" => "assistant",
          "content" => [sibling_text, tool_use(id: "b1", name: "search", input: { "q" => "ordinary" })]
        },
        { "role" => "user", "content" => [tool_result(id: "b1", content: "boom", is_error: true)] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "filler one" }] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "filler two" }] }
      ]

      result = Lain::Context::PurgeFailedInputs.new(turns: 1, protected_patterns: pattern).call(messages)

      redacted_use = result.first["content"].find { |block| block["type"] == "tool_use" }
      expect(redacted_use["input"]).to eq({ "q" => "ordinary" })
    end

    it "Prune, Compact, DedupeToolCalls, and PurgeFailedInputs all exempt the SAME span identically" do
      span = "SAME-PROTECTED-SPAN"

      dedupe_messages = [
        { "role" => "assistant", "content" => [tool_use(id: "c1", name: "search", input: { "q" => span })] },
        { "role" => "user", "content" => [tool_result(id: "c1", content: "first")] },
        { "role" => "assistant", "content" => [tool_use(id: "c2", name: "search", input: { "q" => span })] },
        { "role" => "user", "content" => [tool_result(id: "c2", content: "second")] }
      ]
      purge_messages = [
        { "role" => "assistant", "content" => [tool_use(id: "d1", name: "search", input: { "q" => span })] },
        { "role" => "user", "content" => [tool_result(id: "d1", content: "boom", is_error: true)] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "filler" }] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "filler" }] }
      ]
      prune_messages = [
        { "role" => "user", "content" => [{ "type" => "text", "text" => span }] },
        { "role" => "user", "content" => [{ "type" => "text", "text" => "one" }] },
        { "role" => "user", "content" => [{ "type" => "text", "text" => "two" }] }
      ]
      compact_messages = [
        { "role" => "user", "content" => [{ "type" => "text", "text" => "#{span} #{"a" * 200}" }] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "b" * 200 }] },
        { "role" => "user", "content" => [{ "type" => "text", "text" => "c" * 200 }] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "d" * 200 }] }
      ]
      summarizer = ->(dropped) { "summary of #{dropped.size} turns" }

      dedupe_result = Lain::Context::DedupeToolCalls.new(protected_patterns: pattern).call(dedupe_messages)
      purge_result = Lain::Context::PurgeFailedInputs.new(turns: 1, protected_patterns: pattern).call(purge_messages)
      prune_result = Lain::Context::Prune.new(keep_last: 1, protected_patterns: pattern).call(prune_messages)
      compact_result = Lain::Context::Compact.new(threshold: 10, keep_last: 1, summarizer:,
                                                  protected_patterns: pattern).call(compact_messages)

      expect(dedupe_result).to eq(dedupe_messages)
      expect(purge_result.first["content"].find { |b| b["type"] == "tool_use" }["input"]).to eq({ "q" => span })
      expect(prune_result).to include(prune_messages.first)
      expect(compact_result).to include(compact_messages.first)
    end
  end
end
