# frozen_string_literal: true

RSpec.describe Lain::Compaction::ToolMessages do
  def text(body) = { "type" => "text", "text" => body }

  def message(*blocks, role: "user") = { "role" => role, "content" => blocks }

  def tool_use(id) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => {} }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "ok" }

  describe ".tool?" do
    it "classifies a message carrying any tool block as a tool message" do
      carrying = message(tool_use(0), role: "assistant")

      expect(described_class.tool?(carrying)).to be(true)
    end

    it "classifies an assistant message with text alongside a tool block as still a tool message" do
      mixed = message(text("let me check"), tool_use(0), role: "assistant")

      expect(described_class.tool?(mixed)).to be(true)
    end

    it "classifies a purely conversational message as not a tool message" do
      conversational = message(text("hello"), role: "user")

      expect(described_class.tool?(conversational)).to be(false)
    end
  end

  describe "the two selections, over any span" do
    # Every index in span is EITHER claimed by exactly one of the two
    # selections, or is a lone (run-of-one) conversational message -- the
    # gap {Compaction::Derivation} retains verbatim rather than collapsing.
    # That "modulo the lone runs" clause is not slack in the property: it is
    # the exact shape `.select { |run| run.size > 1 }` (ported from
    # composed_spec.rb:76-79) produces, and AC4 below pins the reason for it.
    # What genuinely must hold unconditionally -- because it is the one
    # thing that makes {Strategy::Composed} not raise `Overlap` -- is that no
    # index is EVER claimed by both.
    def contiguous_runs(span, messages)
      span.select { |index| yield(messages.fetch(index)) }
          .chunk_while { |before, after| after == before + 1 }
          .map { |run| run.first..run.last }
    end

    def random_span(size)
      Array.new(size) { rand < 0.5 ? message(tool_use(0), tool_result(0), role: "assistant") : message(text("hi")) }
    end

    it "never lets the tool runs and the conversational runs claim the same index, across many random spans" do
      200.times do
        messages = random_span(rand(0..12))
        span = 0...messages.size

        tool_indices = described_class.tool_runs(messages, span:, owner: "spec").flat_map(&:to_a)
        conversational_indices = described_class.conversational_runs(messages, span:, owner: "spec").flat_map(&:to_a)

        expect(tool_indices & conversational_indices).to be_empty
      end
    end

    it "accounts for every span index as tool, conversational, or a lone retained conversational run" do
      200.times do
        messages = random_span(rand(0..12))
        span = 0...messages.size

        tool_indices = described_class.tool_runs(messages, span:, owner: "spec").flat_map(&:to_a)
        conversational_indices = described_class.conversational_runs(messages, span:, owner: "spec").flat_map(&:to_a)
        lone_conversational = contiguous_runs(span, messages) { |m| !described_class.tool?(m) }
                              .select { |run| run.size == 1 }
                              .flat_map(&:to_a)

        expect((tool_indices + conversational_indices + lone_conversational).sort).to eq(span.to_a)
      end
    end

    it "matches the runs a plain chunk over the predicate produces, so the IntervalPartition wiring agrees" do
      200.times do
        messages = random_span(rand(0..12))
        span = 0...messages.size

        expected_tool = contiguous_runs(span, messages) { |m| described_class.tool?(m) }
        expected_conversational = contiguous_runs(span, messages) { |m| !described_class.tool?(m) }
                                  .select { |run| run.size > 1 }

        expect(described_class.tool_runs(messages, span:, owner: "spec")).to eq(expected_tool)
        expect(described_class.conversational_runs(messages, span:, owner: "spec")).to eq(expected_conversational)
      end
    end
  end

  describe ".conversational_runs" do
    it "excludes a lone conversational message sitting between two tool runs" do
      messages = [message(tool_use(0), role: "assistant"), message(tool_result(0)),
                  message(text("so"), role: "user"),
                  message(tool_use(1), role: "assistant"), message(tool_result(1))]

      expect(described_class.conversational_runs(messages, span: 0...5, owner: "spec")).to be_empty
    end

    it "keeps a conversational run of more than one message" do
      messages = [message(tool_use(0), role: "assistant"), message(tool_result(0)),
                  message(text("so"), role: "user"), message(text("then"), role: "assistant"),
                  message(tool_use(1), role: "assistant"), message(tool_result(1))]

      expect(described_class.conversational_runs(messages, span: 0...6, owner: "spec")).to eq([2..3])
    end
  end

  describe ".tool_runs" do
    it "selects exactly the contiguous tool-carrying runs" do
      messages = [message(text("ask"), role: "user"),
                  message(tool_use(0), role: "assistant"), message(tool_result(0)),
                  message(text("thanks"), role: "user")]

      expect(described_class.tool_runs(messages, span: 0...4, owner: "spec")).to eq([1..2])
    end
  end
end
