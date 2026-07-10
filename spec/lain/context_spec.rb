# frozen_string_literal: true

require "lain/context"
require "lain/workspace"

RSpec.describe Lain::Workspace do
  it "is empty by default" do
    expect(described_class.empty).to be_empty
  end

  it "is frozen" do
    expect(described_class.new(reminders: ["a"])).to be_frozen
  end

  it "grows into a new value rather than mutating" do
    base = described_class.empty
    grown = base.with("todo: ship M1")
    expect(base).to be_empty
    expect(grown.reminders).to eq(["todo: ship M1"])
  end

  it "renders reminders as tagged text blocks" do
    blocks = described_class.new(reminders: ["remember"]).to_blocks
    expect(blocks).to eq([{ "type" => "text", "text" => "<workspace>remember</workspace>" }])
  end
end

RSpec.describe Lain::Context do
  subject(:context) { described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }

  let(:store) { Lain::Store.new }
  let(:toolset) { Lain::Toolset.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  let(:timeline) do
    Lain::Timeline.empty(store: store)
                  .commit(role: :user, content: text("hello"))
                  .commit(role: :assistant, content: text("hi"))
                  .commit(role: :user, content: text("more"))
  end

  # Purity is not a style preference. It is the same constraint prompt caching
  # imposes: a timestamp in the system prompt invalidates the cached prefix on
  # every turn, costing full input price forever while nothing errors.
  describe "purity" do
    it "renders identical bytes for identical inputs" do
      a = context.render(timeline: timeline, toolset: toolset)
      b = context.render(timeline: timeline, toolset: toolset)
      expect(a.digest).to eq(b.digest)
    end

    it "renders identical bytes across two Contexts built the same way" do
      other = described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
      expect(context.render(timeline: timeline, toolset: toolset).digest)
        .to eq(other.render(timeline: timeline, toolset: toolset).digest)
    end

    it "changes bytes when the timeline changes" do
      longer = timeline.commit(role: :assistant, content: text("and more"))
      expect(context.render(timeline: timeline, toolset: toolset).digest)
        .not_to eq(context.render(timeline: longer, toolset: toolset).digest)
    end
  end

  describe "message rendering" do
    it "orders root first, the order a provider wants" do
      request = context.render(timeline: timeline, toolset: toolset)
      expect(request.messages.map { |m| m["role"] }).to eq(%w[user assistant user])
    end
  end

  describe "cache breakpoints" do
    # Caching the system prompt caches the tools with it, since tools lead the
    # matched prefix.
    it "marks the last system block" do
      request = context.render(timeline: timeline, toolset: toolset)
      expect(request.system.last["cache"]).to be(true)
    end

    it "marks the last content block of the final message" do
      request = context.render(timeline: timeline, toolset: toolset)
      expect(request.messages.last["content"].last["cache"]).to be(true)
    end

    it "leaves earlier short turns unmarked" do
      request = context.render(timeline: timeline, toolset: toolset)
      expect(request.messages.first["content"].last).not_to have_key("cache")
    end

    # Agentic turns pile up tool_use/tool_result pairs and drift outside the
    # 20-block lookback window, so intermediate breakpoints are placed inside it.
    it "adds an intermediate breakpoint on a long turn" do
      fat = Lain::Timeline.empty(store: store)
                          .commit(role: :user, content: Array.new(16) { { "type" => "text", "text" => "x" } })
                          .commit(role: :assistant, content: text("ok"))
      request = context.render(timeline: fat, toolset: toolset)
      expect(request.messages.first["content"].last["cache"]).to be(true)
    end

    it "keeps the intermediate spacing inside the lookback window" do
      expect(described_class::BREAKPOINT_EVERY).to be < described_class::CACHE_LOOKBACK_BLOCKS
    end
  end

  # Sent, not stored. Injecting into `system` would rewrite the cached prefix on
  # every turn; appending to the Timeline would accrete a stale copy per turn.
  describe "workspace injection" do
    let(:workspace) { Lain::Workspace.new(reminders: ["todo: finish M1"]) }

    it "appends workspace blocks to the last user message" do
      request = context.render(timeline: timeline, toolset: toolset, workspace: workspace)
      expect(request.messages.last["content"].map { |b| b["text"] })
        .to eq(["more", "<workspace>todo: finish M1</workspace>"])
    end

    it "never touches the system prompt" do
      with = context.render(timeline: timeline, toolset: toolset, workspace: workspace)
      without = context.render(timeline: timeline, toolset: toolset)
      expect(with.system).to eq(without.system)
    end

    it "never appends to the Timeline" do
      before = timeline.head_digest
      context.render(timeline: timeline, toolset: toolset, workspace: workspace)
      expect(timeline.head_digest).to eq(before)
    end

    it "declines to inject when the last turn is not a user turn" do
      assistant_last = timeline.commit(role: :assistant, content: text("thinking"))
      request = context.render(timeline: assistant_last, toolset: toolset, workspace: workspace)
      expect(request.messages.last["content"].size).to eq(1)
    end
  end

  it "declares the capabilities it needs, so a provider lacking one degrades loudly" do
    expect(context.requires).to include(:prompt_caching)
  end
end
