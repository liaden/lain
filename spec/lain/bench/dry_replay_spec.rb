# frozen_string_literal: true

require "lain/bench/dry_replay"

require "lain/context"
require "lain/context/prune"
require "lain/toolset"

# DryReplay re-renders a RECORDED Timeline under a (possibly different) Context
# and byte-diffs against the recorded baseline. It obtains its inputs the honest
# way: the recorded final Timeline (the real content-addressed DAG a run
# produced) plus the baseline Requests that were actually sent (captured from
# the run's provider), one per model call. Each step's prefix is reconstructed
# from the recorded DAG -- so the byte-identity claim is a real test of
# `Context#render` purity, not a tautology of rendering twice with one object.
RSpec.describe Lain::Bench::DryReplay do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }

  # A genuine two-model-call session: tool_use, then end_turn. The provider
  # records the exact Requests it was handed -- the recorded baseline.
  def record_session(ctx)
    agent, provider = record_run([tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("done")],
                                 toolset: toolset, context: ctx)
    [agent.timeline, provider.requests]
  end

  let(:recorded) { record_session(context) }
  let(:timeline) { recorded.first }
  let(:baseline) { recorded.last }

  def replay(over:)
    described_class.new(timeline: timeline, baseline: baseline, toolset: toolset).diff(over)
  end

  it "records exactly one baseline Request per model call" do
    expect(baseline.size).to eq(2)
  end

  it "reconstructs one step per recorded model call" do
    dr = described_class.new(timeline: timeline, baseline: baseline, toolset: toolset)
    expect(dr.steps).to eq(2)
  end

  it "raises loudly when the baseline does not line up with the recorded DAG" do
    expect { described_class.new(timeline: timeline, baseline: baseline.take(1), toolset: toolset) }
      .to raise_error(ArgumentError, /baseline/)
  end

  describe "under an identity Context (the one that produced the baseline)" do
    it "reproduces byte-identical Requests at every step" do
      diff = replay(over: context)
      expect(diff).to be_identical
      expect(diff.steps.map(&:changed_fields)).to all(be_empty)
    end

    it "matches the recorded bytes digest-for-digest" do
      replayed = described_class.new(timeline: timeline, baseline: baseline, toolset: toolset).replay(context)
      expect(replayed.map(&:digest)).to eq(baseline.map(&:digest))
    end
  end

  describe "under a different Context" do
    let(:louder) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be verbose") }

    it "yields a non-empty diff naming the changed field" do
      diff = replay(over: louder)
      expect(diff).not_to be_identical
      expect(diff.steps.map(&:changed_fields)).to all(include("system"))
    end

    it "is deterministic: same inputs, same diff every time" do
      expect(replay(over: louder)).to eq(replay(over: louder))
    end

    it "produces a Ractor-shareable Diff (deeply frozen value object)" do
      expect(Ractor.shareable?(replay(over: louder))).to be(true)
    end
  end

  describe "under a different render strategy (a pruning pipeline)" do
    # A Context whose pipeline drops all but the last message: a genuine
    # strategy change, flowing through the same #render seam.
    let(:pruning) do
      Class.new(Lain::Context) do
        def self.pipeline(_workspace)
          Lain::Context::Prune.new(keep_last: 1)
        end
      end.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
    end

    it "changes the messages field deterministically" do
      diff = replay(over: pruning)
      expect(diff).not_to be_identical
      expect(diff.steps.last.changed_fields).to include("messages")
      expect(replay(over: pruning)).to eq(replay(over: pruning))
    end
  end
end
