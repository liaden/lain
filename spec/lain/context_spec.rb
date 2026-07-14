# frozen_string_literal: true

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

  # The steady state (Agent renders `@workspace.with(*@session.reminders)`
  # every turn, and reminders is usually empty) must not allocate a fresh
  # Workspace and normalize pass each render.
  it "returns self, allocation-free, when nothing is added" do
    workspace = described_class.new(reminders: ["a"])
    expect(workspace.with).to equal(workspace)
  end
end

RSpec.describe Lain::Context do
  subject(:context) { described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }

  let(:store) { Lain::Store.new }
  let(:toolset) { Lain::Toolset.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  let(:timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("hello"))
                  .commit(role: :assistant, content: text("hi"))
                  .commit(role: :user, content: text("more"))
  end

  # Purity is not a style preference. It is the same constraint prompt caching
  # imposes: a timestamp in the system prompt invalidates the cached prefix on
  # every turn, costing full input price forever while nothing errors.
  describe "purity" do
    it "renders identical bytes for identical inputs" do
      a = context.render(timeline:, toolset:)
      b = context.render(timeline:, toolset:)
      expect(a.digest).to eq(b.digest)
    end

    it "renders identical bytes across two Contexts built the same way" do
      other = described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
      expect(context.render(timeline:, toolset:).digest)
        .to eq(other.render(timeline:, toolset:).digest)
    end

    it "changes bytes when the timeline changes" do
      longer = timeline.commit(role: :assistant, content: text("and more"))
      expect(context.render(timeline:, toolset:).digest)
        .not_to eq(context.render(timeline: longer, toolset:).digest)
    end
  end

  describe "message rendering" do
    it "orders root first, the order a provider wants" do
      request = context.render(timeline:, toolset:)
      expect(request.messages.map { |m| m["role"] }).to eq(%w[user assistant user])
    end
  end

  # Message-block breakpoint PLACEMENT (short-turn skipping, intermediate
  # breakpoints) is owned by spec/lain/context/cache_breakpoints_spec.rb; here we
  # only witness that #render composes the combinator, and cover the system-block
  # marking, which is Context's own code (cache_marked), not a combinator.
  describe "cache breakpoints" do
    # Caching the system prompt caches the tools with it, since tools lead the
    # matched prefix.
    it "marks the last system block" do
      request = context.render(timeline:, toolset:)
      expect(request.system.last["cache"]).to be(true)
    end

    it "composes CacheBreakpoints, marking the last content block of the final message" do
      request = context.render(timeline:, toolset:)
      expect(request.messages.last["content"].last["cache"]).to be(true)
    end

    it "keeps the intermediate spacing inside the lookback window" do
      expect(described_class::BREAKPOINT_EVERY).to be < described_class::CACHE_LOOKBACK_BLOCKS
    end
  end

  # Sent, not stored. Injecting into `system` would rewrite the cached prefix on
  # every turn; appending to the Timeline would accrete a stale copy per turn.
  # The Reminder combinator's own rules (e.g. declining a non-user tail) live in
  # spec/lain/context/reminder_spec.rb; here we witness that #render composes it
  # and cover the two whole-render invariants it must preserve.
  describe "workspace injection" do
    let(:workspace) { Lain::Workspace.new(reminders: ["todo: finish M1"]) }

    it "composes Reminder, appending workspace blocks to the last user message" do
      request = context.render(timeline:, toolset:, workspace:)
      expect(request.messages.last["content"].map { |b| b["text"] })
        .to eq(["more", "<workspace>todo: finish M1</workspace>"])
    end

    it "never touches the system prompt" do
      with = context.render(timeline:, toolset:, workspace:)
      without = context.render(timeline:, toolset:)
      expect(with.system).to eq(without.system)
    end

    it "never appends to the Timeline" do
      before = timeline.head_digest
      context.render(timeline:, toolset:, workspace:)
      expect(timeline.head_digest).to eq(before)
    end
  end

  it "declares the capabilities it needs, so a provider lacking one degrades loudly" do
    expect(context.requires).to include(:prompt_caching)
  end

  # The combinator algebra names itself: the base of the endomorphism monoid is
  # Combinator, and Identity is its unit instance. The old `Base` alias is gone
  # (T16 swept recall.rb/reminder.rb onto Combinator and dropped it).
  describe "the combinator algebra" do
    it "names the base class Combinator" do
      expect(described_class::Combinator).to be_a(Class)
    end

    it "no longer defines the retired Base alias" do
      expect(described_class.const_defined?(:Base, false)).to be(false)
    end

    it "keeps Identity as an instance of Combinator, the monoid unit" do
      expect(described_class::Identity).to be_an_instance_of(described_class::Combinator)
    end
  end

  # Provider-specific sampler params (temperature, seed, num_ctx) ride
  # Request#extra, which Request excludes from cache_payload/digest by design.
  # Context threads them through render WITHOUT letting them enter cache
  # identity -- two runs at different temperatures are the same prompt.
  describe "extra passthrough" do
    let(:sampler) { { "temperature" => 0, "seed" => 7 } }

    it "defaults extra to empty" do
      expect(described_class.new(model: "qwen3:4b", max_tokens: 1024).extra).to eq({})
    end

    it "threads extra into the rendered Request" do
      ctx = described_class.new(model: "qwen3:4b", max_tokens: 1024, extra: sampler)
      expect(ctx.render(timeline:, toolset:).extra).to include("temperature" => 0, "seed" => 7)
    end

    it "keeps extra out of cache identity" do
      plain = described_class.new(model: "qwen3:4b", max_tokens: 1024)
      tuned = described_class.new(model: "qwen3:4b", max_tokens: 1024, extra: sampler)
      expect(tuned.render(timeline:, toolset:).digest)
        .to eq(plain.render(timeline:, toolset:).digest)
    end

    it "renders identical bytes for identical extra (purity preserved)" do
      ctx = described_class.new(model: "qwen3:4b", max_tokens: 1024, extra: sampler)
      expect(ctx.render(timeline:, toolset:).digest).to eq(ctx.render(timeline:, toolset:).digest)
    end
  end

  # Comment #6: cache-marking must not type-branch on the system prompt. A
  # String system and its already-blocked equivalent must render to the same
  # bytes -- one normalization, one code path downstream.
  describe "system normalization" do
    it "renders a String system prompt as a single cache-marked text block" do
      request = context.render(timeline:, toolset:)
      expect(request.system).to eq([{ "type" => "text", "text" => "be terse", "cache" => true }])
    end

    it "renders a block-form system prompt to the same bytes as its String form" do
      blocks = described_class.new(model: "claude-opus-4-8", max_tokens: 1024,
                                   system: [{ "type" => "text", "text" => "be terse" }])
      expect(blocks.render(timeline:, toolset:).digest)
        .to eq(context.render(timeline:, toolset:).digest)
    end

    # The normalization lives in render, NOT in the stored value: Bench::Session
    # serializes Context#system into its header (spec/lain/bench/session_spec.rb
    # pins "system" => "be terse"), so the reader must keep the caller's shape.
    it "keeps Context#system in the shape it was given" do
      expect(context.system).to eq("be terse")
    end
  end
end
