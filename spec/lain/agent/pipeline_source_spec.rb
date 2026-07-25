# frozen_string_literal: true

RSpec.describe Lain::Agent::PipelineSource::Null do
  let(:base) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:timeline) { Lain::Timeline.empty(store: Lain::Store.new) }
  let(:session) { Lain::Session.new }

  def context_for(**overrides)
    described_class.context_for(base:, timeline:, usage: 1_000, session:, **overrides)
  end

  # A real Null Object, not a nil sentinel: it answers the SAME Context object,
  # so `#render` runs against the identical frozen value it always did and no
  # caller ever writes `if source`.
  it "answers the base Context itself, identity and all" do
    expect(context_for).to be(base)
  end

  it "answers the base before any turn has reported usage" do
    expect(context_for(usage: nil)).to be(base)
  end

  it "accepts the whole per-turn duck -- base:, timeline:, usage:, session:" do
    expect { context_for }.not_to raise_error
  end

  # The default must not be the thing that costs a Context its shareability:
  # `Scheduler::COMPOSE` calls `Ractor.make_shareable` on a lambda closing over
  # the pipeline, so anything on this path that holds mutable state poisons it.
  it "is itself Ractor-shareable" do
    expect(described_class).to be_ractor_shareable
  end
end
