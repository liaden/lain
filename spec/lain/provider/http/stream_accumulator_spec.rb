# frozen_string_literal: true

# Ported near-verbatim from ruby_llm 1.16.0 (2cf34b9),
# spec/ruby_llm/stream_accumulator_spec.rb. Only the namespace changed
# (RubyLLM:: -> Lain::Provider::HTTP::). This is the one spec in the vendored
# slice that exercises `input_json_delta` chunk-boundary reassembly by
# feeding the accumulator deliberately-split fragments -- VCR cannot prove
# this (see the porting plan's "Testing strategy"), so it earns its place
# on its own merits regardless of what else is ported.
RSpec.describe Lain::Provider::HTTP::StreamAccumulator do
  describe "#add" do
    it "handles tool call deltas that omit arguments" do
      accumulator = described_class.new
      tool_call = Lain::Provider::HTTP::ToolCall.new(id: "call_1", name: "weather", arguments: nil)
      chunk = Lain::Provider::HTTP::Chunk.new(role: :assistant, content: nil, tool_calls: { "call_1" => tool_call })

      expect { accumulator.add(chunk) }.not_to raise_error

      message = accumulator.to_message(nil)
      expect(message.tool_calls["call_1"].arguments).to eq({})
    end

    it "keeps interleaved tool call fragments separate by stream key" do
      accumulator = described_class.new

      chunks = [
        { 1 => Lain::Provider::HTTP::ToolCall.new(id: "call_1", name: "market_data", arguments: {}) },
        { 2 => Lain::Provider::HTTP::ToolCall.new(id: "call_2", name: "search", arguments: {}) },
        { 1 => Lain::Provider::HTTP::ToolCall.new(id: nil, name: nil, arguments: '{"symbol":"MNQM26",') },
        { 2 => Lain::Provider::HTTP::ToolCall.new(id: nil, name: nil, arguments: '{"query":"market news",') },
        { 1 => Lain::Provider::HTTP::ToolCall.new(id: nil, name: nil, arguments: '"interval":"minute"}') },
        { 2 => Lain::Provider::HTTP::ToolCall.new(id: nil, name: nil, arguments: '"date":"2026-03-31"}') }
      ]

      chunks.each do |tool_calls|
        accumulator.add(Lain::Provider::HTTP::Chunk.new(role: :assistant, content: nil, tool_calls:))
      end

      message = accumulator.to_message(nil)

      expect(message.tool_calls["call_1"].arguments).to eq(
        "symbol" => "MNQM26",
        "interval" => "minute"
      )
      expect(message.tool_calls["call_2"].arguments).to eq(
        "query" => "market news",
        "date" => "2026-03-31"
      )
    end
  end
end
