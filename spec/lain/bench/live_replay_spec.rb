# frozen_string_literal: true

require "json"
require "stringio"

require "lain/bench/live_replay"

require "lain/agent"
require "lain/context"
require "lain/journal"
require "lain/provider/mock"
require "lain/response"
require "lain/toolset"
require "lain/tool"
require "lain/usage"

# LiveReplay re-runs a recorded task against a real provider, SEQUENTIALLY (n:
# sweeps are deferred to the M5 concurrency choice), and records fresh
# Usage/Journal. The network path is exercised only under :live; the mechanics
# below drive it with Provider::Mock, which never touches the network, so they
# are safe untagged.
RSpec.describe Lain::Bench::LiveReplay do
  echo_tool = Class.new(Lain::Tool) do
    def name = "echo"
    def description = "Echoes."
    def input_schema = { type: :object, properties: { text: { type: :string } }, required: [:text] }

    def perform(input, _context) = Lain::Tool::Result.ok(input.fetch("text"))
  end

  let(:toolset) { Lain::Toolset.new([echo_tool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  describe ".prompts_from" do
    it "extracts only the human asks, skipping tool_result user turns" do
      provider = Lain::Provider::Mock.new(responses: [
                                            tool_use("t1"),
                                            Lain::Response.new(content: [{ "type" => "text", "text" => "done" }],
                                                               stop_reason: :end_turn)
                                          ])
      agent = Lain::Agent.new(provider: provider, toolset: toolset, context: context)
      agent.ask("please echo hi")

      expect(described_class.prompts_from(agent.timeline)).to eq(["please echo hi"])
    end
  end

  describe "#replay" do
    let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

    let(:live_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "pong" }],
                                                    stop_reason: :end_turn, usage: usage, model: "claude-opus-4-8")
                               ])
    end

    let(:replay) do
      described_class.new(provider: live_provider, toolset: toolset, context: context, journal: journal)
    end

    it "re-runs the task and returns a fresh Timeline and Usage" do
      result = replay.replay(["say pong"])

      expect(result.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      expect(result.usage.total_tokens).to eq(150)
      expect(result.responses.first.text).to eq("pong")
    end

    it "drives the prompts sequentially, one ask per prompt" do
      replay.replay(["say pong"])
      expect(live_provider.call_count).to eq(1)
    end

    it "records a fresh usage summary to the Journal, priced by the context model" do
      replay.replay(["say pong"])

      summary = records.find { |r| r["type"] == "live_replay" }
      expect(summary).not_to be_nil
      expect(summary.dig("usage", "output_tokens")).to eq(30)
      expect(BigDecimal(summary.fetch("cost"))).to be > 0
    end

    it "records one turn record per prompt" do
      replay.replay(["say pong"])
      expect(records.count { |r| r["type"] == "live_replay_turn" }).to eq(1)
    end
  end

  # The one network-touching example: real money, opt-in (LAIN_LIVE=1 + a key),
  # skipped otherwise. It re-runs a trivial recorded task against the API and
  # asserts fresh usage came back and was journaled.
  describe "against the real API", :live do
    it "re-runs the task live and records fresh Usage" do
      require "lain/provider/anthropic"

      replay = described_class.new(
        provider: Lain::Provider::Anthropic.new,
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 16, system: "Reply with one word."),
        journal: journal
      )

      result = replay.replay(["Reply with the single word: pong"])

      expect(result.usage.total_tokens).to be > 0
      expect(records.find { |r| r["type"] == "live_replay" }).not_to be_nil
    end
  end

  def tool_use(id)
    Lain::Response.new(
      content: [{ "type" => "tool_use", "id" => id, "name" => "echo", "input" => { "text" => "hi" } }],
      stop_reason: :tool_use
    )
  end
end
