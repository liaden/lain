# frozen_string_literal: true

require "json"
require "stringio"

# Shareable fixtures. The scheduler makes the pipeline it composes shareable, so
# the injected compact/base it closes over MUST already be shareable -- the
# production contract (a Context storing the pipeline must stay shareable). These
# live in a module body -- like T21PipelineProviders in context_spec -- so each
# lambda's `self` is this (shareable) module rather than an example instance,
# which is what lets `Ractor.make_shareable` accept them at all.
module SchedulerShareableFixtures
  SUMMARIZER = Ractor.make_shareable(->(_dropped) { "SUMMARY" })
  BASE = Ractor.make_shareable(->(_workspace) { Lain::Context::Identity })
end

RSpec.describe Lain::Compaction::Scheduler do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  # A deterministic, pure, SHAREABLE summarizer -- the Compact contract (see
  # compact.rb). It collapses whatever head it is handed into one recognizable
  # marker so a spec can assert "the head was rewritten" without depending on
  # real text. Shareable because the scheduler makes the composed pipeline
  # shareable, so what it closes over must be too.
  let(:compact) do
    Lain::Context::Compact.new(threshold: 5, keep_last: 2, summarizer: SchedulerShareableFixtures::SUMMARIZER)
  end

  # The strategy #render would use without the scheduler: a shareable
  # `->(workspace)` provider (T21's injected shape) resolving to the identity
  # combinator, so applying it leaves the message list untouched. A compacting
  # decision rides Compact ahead of THIS; a deferring decision hands it back.
  let(:base) { SchedulerShareableFixtures::BASE }

  # Six substantial messages: enough that Compact's keep_last(2) leaves a head
  # over its byte threshold, so a scheduled compaction actually rewrites it.
  def history(size = 6)
    (1...(size + 1)).map do |i|
      { "role" => "user", "content" => [{ "type" => "text", "text" => "the quick brown fox number #{i}" }] }
    end
  end

  def need(*signals) = Lain::Compaction::Need::Result.new(signals:)

  # Runs the scheduler's chosen pipeline against `messages` the way #render
  # would: resolve the provider for a workspace, then apply it.
  def rendered(pipeline, messages)
    pipeline.call(Lain::Workspace.empty).call(messages)
  end

  def scheduler(hard_cap: 1_000_000)
    described_class.new(compact:, hard_cap:, journal:)
  end

  describe "#evaluate (the pure policy)" do
    it "defers a needed compaction while warm and below the hard cap" do
      decision = scheduler.evaluate(need: need(:token_threshold), cold: false, history_size: 10)

      expect(decision.compact?).to be(false)
    end

    it "forces (message-tier) a needed compaction that crosses the hard cap while warm" do
      decision = scheduler(hard_cap: 100).evaluate(need: need(:token_threshold), cold: false, history_size: 100)

      expect(decision.compact?).to be(true)
      expect(decision.tier).to eq(:message)
    end

    it "forces (message-tier) a needed compaction approaching the window while warm" do
      decision = scheduler.evaluate(need: need(:approaching_window), cold: false, history_size: 10)

      expect(decision.compact?).to be(true)
      expect(decision.tier).to eq(:message)
    end

    it "runs a needed compaction for free once the cache is cold, regardless of cap" do
      decision = scheduler.evaluate(need: need(:token_threshold), cold: true, history_size: 10)

      expect(decision.compact?).to be(true)
    end

    it "defers when no compaction is warranted, even cold and over the cap" do
      decision = scheduler(hard_cap: 1).evaluate(need:, cold: true, history_size: 999)

      expect(decision.compact?).to be(false)
    end
  end

  describe "#pipeline" do
    it "hands the base back UNTOUCHED (same object) when it defers -- a non-compacting turn is unchanged" do
      pipeline = scheduler.pipeline(need: need(:token_threshold), cold: false, history_size: 10, base:)

      expect(pipeline).to equal(base)
      expect(rendered(pipeline, history)).to eq(history)
      expect(records).to be_empty
    end

    it "hands the base back untouched and journals nothing when no compaction is warranted" do
      pipeline = scheduler(hard_cap: 1).pipeline(need:, cold: true, history_size: 999, base:)

      expect(pipeline).to equal(base)
      expect(records).to be_empty
    end

    it "crossing the hard cap while warm runs the compaction and notes forced-warm, message-tier only" do
      pipeline = scheduler(hard_cap: 100).pipeline(need: need(:token_threshold), cold: false, history_size: 100, base:)

      result = rendered(pipeline, history)

      expect(result.size).to be < history.size
      expect(result).to include(a_hash_including("content" => [a_hash_including("text" => "SUMMARY")]))
      expect(records).to contain_exactly(
        a_hash_including("type" => "compaction_scheduled", "reason" => "forced_warm", "tier" => "message")
      )
    end

    it "runs a needed compaction for free while the cache is cold" do
      pipeline = scheduler.pipeline(need: need(:token_threshold), cold: true, history_size: 10, base:)

      result = rendered(pipeline, history)

      expect(result.size).to be < history.size
      expect(records.map { |r| r["reason"] }).to eq(["cold_free"])
    end

    it "leaves the injected base pipeline unmutated across a compacting decision (renders stay pure)" do
      scheduler(hard_cap: 100).pipeline(need: need(:token_threshold), cold: false, history_size: 100, base:)

      # The base provider still resolves to the bare identity: the scheduler
      # composed a NEW pipeline rather than reaching into this one.
      expect(rendered(base, history)).to eq(history)
    end
  end

  # The contract T19 builds on: a compacting pipeline must be Ractor-shareable,
  # so `Context.new(pipeline: scheduler.pipeline(...))` (T21's seam) holds a
  # value with no reachable mutable state -- crucially not the scheduler's own
  # live IO-backed Journal. A provider built inside an instance method captures
  # that `self` in its binding and fails this; the module-scope COMPOSE lambda
  # closes over its shareable args alone.
  describe "the composed pipeline is Ractor-shareable (T21/T19 contract)" do
    def shared_pipeline
      scheduler(hard_cap: 100).pipeline(need: need(:token_threshold), cold: false, history_size: 100, base:)
    end

    it "stays shareable when the injected compact and base are, despite the live Journal" do
      pipeline = shared_pipeline

      expect(Ractor.shareable?(pipeline)).to be(true)
      expect { Ractor.make_shareable(pipeline) }.not_to raise_error
    end

    it "survives being stored in a Context via the injected-pipeline seam" do
      context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, pipeline: shared_pipeline)

      expect(Ractor.shareable?(context)).to be(true)
    end

    it "fails LOUDLY when a caller injects a non-shareable compact (contract enforced at compose)" do
      leaky_summarizer = ->(_dropped) { "SUMMARY" } # self is this example -- not shareable
      leaky = described_class.new(
        compact: Lain::Context::Compact.new(threshold: 5, keep_last: 2, summarizer: leaky_summarizer),
        hard_cap: 100, journal:
      )

      expect do
        leaky.pipeline(need: need(:token_threshold), cold: false, history_size: 100, base:)
      end.to raise_error(Ractor::IsolationError)
    end
  end
end
