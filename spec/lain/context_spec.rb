# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Workspace do
  it "is empty by default" do
    expect(described_class.empty).to be_empty
  end

  it "is frozen" do
    expect(described_class.new(reminders: ["a"])).to be_deeply_frozen
  end

  it "grows into a new value rather than mutating" do
    base = described_class.empty
    grown = base.with("todo: ship M1")
    expect(base).to be_empty
    expect(grown.reminders).to eq(["todo: ship M1"])
  end

  it "renders reminders as tagged text blocks carrying the structural workspace marker" do
    blocks = described_class.new(reminders: ["remember"]).to_blocks
    expect(blocks).to eq(
      [{ "type" => "text", "text" => "<workspace>remember</workspace>", described_class::WORKSPACE_MARKER => true }]
    )
  end

  # The steady state (Agent renders `@workspace.with(*@session.reminders)`
  # every turn, and reminders is usually empty) must not allocate a fresh
  # Workspace and normalize pass each render.
  it "returns self, allocation-free, when nothing is added" do
    workspace = described_class.new(reminders: ["a"])
    expect(workspace.with).to equal(workspace)
  end
end

# A pure ->(workspace) pipeline provider for T21's injection seam. Defined in a
# module body so its `self` is this (Ractor-shareable) module, which is what
# lets the lambda -- and thus a Context that stores it -- stay shareable. It
# reproduces the class default (Reminder >> CacheBreakpoints) so an injected
# render can be pinned byte-for-byte against the default one.
module T21PipelineProviders
  DEFAULT = Ractor.make_shareable(
    ->(workspace) { Lain::Context::Reminder.new(workspace:) >> Lain::Context::CacheBreakpoints.new }
  )
end

# A1's counter-example: the hand-rolled base a per-turn source composes around
# when it does NOT read #pipeline_for. It marks cache breakpoints and omits
# Reminder, which is the exact shape bench/plan_sweep/driver.rb's BASE_PIPELINE
# has -- the one precedent a compaction source would copy.
module WithPipelineBases
  CACHE_ONLY = Ractor.make_shareable(->(_workspace) { Lain::Context::CacheBreakpoints.new })
end

RSpec.describe Lain::Context do
  subject(:context) { described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }

  let(:store) { Lain::Store.new }
  let(:toolset) { Lain::Toolset.new }
  let(:timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("hello"))
                  .commit(role: :assistant, content: text("hi"))
                  .commit(role: :user, content: text("more"))
  end

  def text(body) = [{ "type" => "text", "text" => body }]

  # Purity is not a style preference. It is the same constraint prompt caching
  # imposes: a timestamp in the system prompt invalidates the cached prefix on
  # every turn, costing full input price forever while nothing errors.
  describe "purity" do
    it "renders identical bytes for identical inputs" do
      a = context.render(timeline:, toolset:)
      b = context.render(timeline:, toolset:)
      expect(a).to have_same_digest_as(b)
    end

    it "renders identical bytes across two Contexts built the same way" do
      other = described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
      expect(context.render(timeline:, toolset:)).to have_same_digest_as(other.render(timeline:, toolset:))
    end

    it "changes bytes when the timeline changes" do
      longer = timeline.commit(role: :assistant, content: text("and more"))
      expect(context.render(timeline:, toolset:)).not_to have_same_digest_as(context.render(timeline: longer, toolset:))
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
      expect(tuned.render(timeline:, toolset:)).to have_same_digest_as(plain.render(timeline:, toolset:))
    end

    it "renders identical bytes for identical extra (purity preserved)" do
      ctx = described_class.new(model: "qwen3:4b", max_tokens: 1024, extra: sampler)
      expect(ctx.render(timeline:, toolset:)).to have_same_digest_as(ctx.render(timeline:, toolset:))
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
      expect(blocks.render(timeline:, toolset:)).to have_same_digest_as(context.render(timeline:, toolset:))
    end

    # The normalization lives in render, NOT in the stored value: Bench::Session
    # serializes Context#system into its header (spec/lain/bench/session_spec.rb
    # pins "system" => "be terse"), so the reader must keep the caller's shape.
    it "keeps Context#system in the shape it was given" do
      expect(context.system).to eq("be terse")
    end
  end

  # T21: the render pipeline is an INJECTED collaborator, not a fixed class
  # method. A default Context (no pipeline:) must render byte-identically to the
  # hardcoded Reminder >> CacheBreakpoints, so injection is a pure seam and not a
  # behavior change. An injected combinator or ->(workspace) provider routes both
  # #render and #requires, so declared capabilities cannot drift from behavior.
  describe "render-pipeline injection" do
    let(:workspace) { Lain::Workspace.new(reminders: ["todo: finish M1"]) }

    # The seam's non-negotiable guard: constructing with the explicit default
    # pipeline must reproduce the default render's bytes exactly, workspace and
    # all -- proof the default path is a pure pass-through equal to the injected
    # Reminder >> CacheBreakpoints.
    it "renders byte-identically to the default when given the explicit default pipeline" do
      injected = described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse",
                                     pipeline: T21PipelineProviders::DEFAULT)
      expect(injected.render(timeline:, toolset:, workspace:))
        .to have_same_digest_as(context.render(timeline:, toolset:, workspace:))
    end

    it "leaves the default Context's REQUIRES a static constant" do
      expect(context.requires).to eq(described_class::REQUIRES)
      expect(described_class::REQUIRES).to include(:prompt_caching)
    end

    it "routes render through an injected combinator instead of the default" do
      injected = described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse",
                                     pipeline: Lain::Context::Identity)
      request = injected.render(timeline:, toolset:, workspace:)
      # Identity marks no cache breakpoint and appends no workspace tail, so the
      # last message keeps its single original block, unmarked.
      expect(request.messages.last["content"].last).not_to have_key("cache")
      expect(request.messages.last["content"].map { |b| b["text"] }).to eq(["more"])
    end

    it "derives #requires from an injected combinator's #requires" do
      injected = described_class.new(model: "claude-opus-4-8", max_tokens: 1024,
                                     pipeline: Lain::Context::Identity)
      expect(injected.requires).to eq(Lain::Context::Identity.requires)
      expect(injected.requires).not_to include(:prompt_caching)
    end

    it "derives #requires from an injected ->(workspace) provider's pipeline" do
      injected = described_class.new(model: "claude-opus-4-8", max_tokens: 1024,
                                     pipeline: T21PipelineProviders::DEFAULT)
      expect(injected.requires).to eq(described_class::REQUIRES)
    end

    # The no-injection path must derive #requires from the pipeline that
    # ACTUALLY runs (self.class.pipeline), never shortcut to the base REQUIRES
    # constant. A subclass overriding self.pipeline renders via #pipeline_for;
    # #requires must agree, or Capability::Policy would degrade/raise for a
    # capability the subclass's real pipeline never uses.
    it "derives #requires from a self.pipeline-overriding subclass's own pipeline, not base REQUIRES" do
      pruning = Class.new(described_class) do
        def self.pipeline(_workspace) = Lain::Context::Prune.new(keep_last: 1)
      end
      ctx = pruning.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")

      expect(ctx.requires).to eq(pruning.pipeline(Lain::Workspace.empty).requires)
      expect(ctx.requires).not_to eq(described_class::REQUIRES)
    end

    # Documented tradeoff, pinned so it is never silent: a RAW Combinator
    # injected as `pipeline:` freezes the Workspace it was built with --
    # #pipeline_for hands it back untouched, so the per-render Workspace is
    # ignored. A stage needing the live Workspace must use the provider form.
    it "pins the raw-Combinator stale-workspace trap: the build-time Workspace wins over the render one" do
      raw = Lain::Context::Reminder.new(workspace: Lain::Workspace.new(reminders: ["BUILD-TIME"])) >>
            Lain::Context::CacheBreakpoints.new
      ctx = described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse", pipeline: raw)

      tail = ctx.render(timeline:, toolset:, workspace: Lain::Workspace.new(reminders: ["LIVE"]))
                .messages.last["content"].map { |block| block["text"] }
      expect(tail).to include("<workspace>BUILD-TIME</workspace>")
      expect(tail).not_to include("<workspace>LIVE</workspace>")
    end

    # The escape hatch the trap above points at: the ->(workspace) provider
    # form is rebuilt against each render's Workspace, so it tracks the live one.
    it "the ->(workspace) provider form tracks the live per-render Workspace" do
      ctx = described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse",
                                pipeline: T21PipelineProviders::DEFAULT)
      tail = ctx.render(timeline:, toolset:, workspace: Lain::Workspace.new(reminders: ["LIVE"]))
                .messages.last["content"].map { |block| block["text"] }
      expect(tail).to include("<workspace>LIVE</workspace>")
    end

    describe "purity and shareability with an injected pipeline" do
      let(:injected) do
        described_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse",
                            pipeline: Lain::Context::Identity)
      end

      it "renders identical bytes for identical inputs" do
        expect(injected.render(timeline:, toolset:)).to have_same_digest_as(injected.render(timeline:, toolset:))
      end

      it "stays deeply frozen and Ractor-shareable" do
        expect(injected).to be_ractor_shareable
      end
    end
  end

  # A1's mirror of #with_model: the copy-with that lets a per-turn source swap
  # the render strategy without the Context's owner rebuilding it from parts.
  describe "#with_pipeline" do
    let(:built) do
      described_class.new(model: "claude-opus-4-8", max_tokens: 64, system: "be terse",
                          stream: false, extra: { "temperature" => 0.2 })
    end

    it "keeps everything but the pipeline" do
      copy = built.with_pipeline(Lain::Context::Identity)

      expect([copy.model, copy.max_tokens, copy.system, copy.stream, copy.extra])
        .to eq(["claude-opus-4-8", 64, "be terse", false, { "temperature" => 0.2 }])
    end

    it "renders through the new pipeline, not the one it was built with" do
      copy = built.with_pipeline(Lain::Context::Identity)
      tail = copy.render(timeline:, toolset:, workspace: Lain::Workspace.new(reminders: ["LIVE"]))
                 .messages.last

      expect(tail["content"].map { |block| block["text"] }).to eq(["more"])
      expect(tail["content"].last).not_to have_key("cache")
    end

    it "leaves the receiver untouched -- a copy, because Context is frozen by design" do
      built.with_pipeline(Lain::Context::Identity)

      expect(built.render(timeline:, toolset:).messages.last["content"].last).to have_key("cache")
    end

    # #requires is DERIVED from the effective pipeline (see #initialize), so a
    # copy declares the capabilities its own strategy needs, never the ones it
    # inherited. Drift here is what Capability::Policy would act on.
    it "re-derives #requires from the new pipeline" do
      copy = built.with_pipeline(Lain::Context::Identity)

      expect(built.requires).to include(:prompt_caching)
      expect(copy.requires).to eq(Lain::Context::Identity.requires)
    end

    it "stays Ractor-shareable when the injected pipeline is" do
      expect(built.with_pipeline(Lain::Context::Prune.new(keep_last: 1))).to be_ractor_shareable
    end

    # AC5, and the trap it exists for: `model:` in a copy-with must be the
    # STORED slot, never the `#model` reader -- the reader unwraps to
    # `.current`, so writing it here would freeze a live ModelSwitch at the
    # value it happened to hold and silently break `/model` from the next turn
    # on. #with_model passes its own shadowed parameter, so it never had this
    # shape to get wrong; #with_pipeline does.
    it "preserves a live model switch instead of flattening it to the model in force" do
      journal = Lain::Journal.new(io: StringIO.new)
      switch = Lain::Context::ModelSwitch.new("claude-opus-4-8", journal:)
      copy = built.with_model(switch).with_pipeline(Lain::Context::Identity)
      switch.switch("claude-haiku-4-5", surface: "tty")

      expect(copy.render(timeline:, toolset:).model).to eq("claude-haiku-4-5")
      expect(copy.model).to eq("claude-haiku-4-5")
    end

    # #with_pipeline is a write, and A6 needs the matching READ: to compose
    # Compact AHEAD of whatever this Context would otherwise render through, it
    # must be able to ask. #pipeline_for is that read, and it is public for
    # exactly this round trip.
    describe "the read that closes the loop -- #pipeline_for" do
      it "round-trips: reading the effective pipeline and writing it back changes nothing" do
        same = built.with_pipeline(built.pipeline_for(Lain::Workspace.empty))

        expect(same.requires).to eq(built.requires)
        expect(same.render(timeline:, toolset:)).to eq(built.render(timeline:, toolset:))
      end

      it "answers an INJECTED pipeline, which self.class.pipeline silently discards" do
        injected = built.with_pipeline(Lain::Context::Identity)

        expect(injected.pipeline_for(Lain::Workspace.empty)).to be(Lain::Context::Identity)
        expect(described_class.pipeline(Lain::Workspace.empty).requires).to include(:prompt_caching)
        expect(injected.pipeline_for(Lain::Workspace.empty).requires).to eq([])
      end

      # The ->(workspace) provider form is rebuilt per render, so the read has
      # to be per-workspace too -- a source that wraps it must pass the live
      # Workspace through, not Workspace.empty, or the reminders it composes
      # around are the wrong ones.
      it "builds a provider-form pipeline against the workspace it is asked about" do
        ctx = described_class.new(model: "claude-opus-4-8", max_tokens: 1024,
                                  pipeline: T21PipelineProviders::DEFAULT)
        live = Lain::Workspace.new(reminders: ["LIVE"])

        rendered = ctx.pipeline_for(live).call([{ "role" => "user", "content" => [] }])
        expect(rendered.last["content"].map { |block| block["text"] }).to include("<workspace>LIVE</workspace>")
      end

      # The hazard this read exists to prevent, pinned so it cannot re-hide:
      # composing around a hand-rolled base that omits Reminder loses the
      # Session's live reminders, and #requires does NOT notice -- the composed
      # requires is a union, so it still reports :prompt_caching.
      it "pins that a Reminder-less base loses reminders while #requires still reports prompt_caching" do
        reminderless = built.with_pipeline(WithPipelineBases::CACHE_ONLY)
        live = Lain::Workspace.new(reminders: ["REMEMBER-ME"])

        expect(reminderless.requires).to eq(built.requires)
        expect(reminderless.render(timeline:, toolset:, workspace: live).messages.to_s)
          .not_to include("REMEMBER-ME")
        expect(built.render(timeline:, toolset:, workspace: live).messages.to_s).to include("REMEMBER-ME")
      end
    end
  end
end
