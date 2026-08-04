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

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

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

  def scheduler(hard_cap: 1_000_000, model: nil)
    described_class.new(compact:, hard_cap:, journal:, model:)
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

  # T17. What a scheduled rewrite would cost, as a value: the bytes the messages
  # dump to now and the bytes they dump to once this scheduler's Compact has had
  # them. It is the ONE object holding the Compact, so it is the only one that
  # can measure -- and taking the measurement once is what lets the caller's
  # "is this rewrite worth making" and this object's journalled accounting read
  # the same two numbers instead of computing them twice.
  describe "#measure" do
    it "measures the messages as they are and as its Compact leaves them" do
      measured = scheduler.measure(history)

      expect(measured.before).to eq(Lain::Canonical.dump(history).bytesize)
      expect(measured.after).to eq(Lain::Canonical.dump(compact.call(history)).bytesize)
    end

    it "answers whether the rewrite shrinks the rendered history" do
      expect(scheduler.measure(history).shrinks?).to be(true)
    end

    # STRICT, the floor {Compaction::Source} applies: a byte-neutral rewrite
    # buys nothing and still breaks the cache prefix.
    it "declines a rewrite that changes nothing" do
      neutral = described_class.new(compact: Lain::Context::Identity, hard_cap: 1, journal:)

      expect(neutral.measure(history).shrinks?).to be(false)
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
      built = scheduler(hard_cap: 100)
      pipeline = built.pipeline(need: need(:token_threshold), cold: false, history_size: 100,
                                base:, rewrite: built.measure(history))

      result = rendered(pipeline, history)

      expect(result.size).to be < history.size
      expect(result).to include(a_hash_including("content" => [a_hash_including("text" => "SUMMARY")]))
      expect(records).to contain_exactly(
        a_hash_including("type" => "compaction", "trigger" => ["token_threshold"], "cache_state" => "forced")
      )
    end

    it "runs a needed compaction for free while the cache is cold" do
      built = scheduler
      pipeline = built.pipeline(need: need(:token_threshold), cold: true, history_size: 10,
                                base:, rewrite: built.measure(history))

      result = rendered(pipeline, history)

      expect(result.size).to be < history.size
      expect(records.map { |r| r["cache_state"] }).to eq(["cold"])
    end

    # C2's seam. The model in force is a fact about the TURN, not about the
    # scheduler's configuration, so it arrives per call rather than being
    # captured at construction -- which is also what keeps the Scheduler frozen
    # and everything it hands back shareable.
    it "takes the model in force per turn and never lets it move the decision" do
      built = scheduler(hard_cap: 100, model: "claude-sonnet-4-6")
      pipeline = built.pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:,
        rewrite: built.measure(history), ran_under: "claude-opus-4-8"
      )

      expect(rendered(pipeline, history)).to include(
        a_hash_including("content" => [a_hash_including("text" => "SUMMARY")])
      )
      expect(records.map { |r| r["cache_state"] }).to eq(["forced"])
    end

    # T17. The accounting used to run the compact and dump both sides ITSELF,
    # and its caller had already done exactly that to decide whether the rewrite
    # was worth making at all -- two Canonical passes over the whole history,
    # per compacting turn, for two numbers that were already known. The
    # measurement is a value now, taken once and handed in.
    it "journals the measurement it is handed rather than taking its own" do
      built = scheduler(hard_cap: 100)
      measured = built.measure(history)
      allow(Lain::Canonical).to receive(:dump).and_call_original

      built.pipeline(need: need(:token_threshold), cold: false, history_size: 100, base:, rewrite: measured)

      expect(Lain::Canonical).not_to have_received(:dump)
      expect(records.first)
        .to include("tokens_before" => measured.before, "tokens_after" => measured.after)
    end

    # T17 review fix 3, and the card's own sin caught: the measurement must not
    # be a DEFAULT ARGUMENT. A default is evaluated on every call, so measuring
    # there runs the Compact and both dumps on the deferring turns -- the steady
    # state -- which `if decision.compact?` had always kept free. New
    # unconditional work, on a card whose whole point is deleting it.
    #
    # Counted through `Canonical.dump` rather than by proxying the Compact: a
    # Compact is a frozen value and rspec-mocks cannot proxy one, which is
    # itself the reason a measurement has to be threaded rather than spied on.
    it "measures nothing at all on a turn it defers" do
      allow(Lain::Canonical).to receive(:dump).and_call_original

      scheduler.pipeline(need: need(:token_threshold), cold: false, history_size: 10, base:)

      expect(Lain::Canonical).not_to have_received(:dump)
    end

    # The other half of that fix: a caller that names no rewrite still journals
    # exactly the bytes it always did, so moving the measurement off the
    # signature moved no figure.
    it "measures the empty history for a caller that names no rewrite, as it always did" do
      built = scheduler(hard_cap: 100)

      built.pipeline(need: need(:token_threshold), cold: false, history_size: 100, base:)

      expect(records.first).to include("tokens_before" => built.measure([]).before,
                                       "tokens_after" => built.measure([]).after)
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
  describe "the composed pipeline is Ractor-shareable" do
    def shared_pipeline
      scheduler(hard_cap: 100).pipeline(need: need(:token_threshold), cold: false, history_size: 100, base:)
    end

    it "stays shareable when the injected compact and base are, despite the live Journal" do
      pipeline = shared_pipeline

      expect(pipeline).to be_deeply_frozen
      expect { Ractor.make_shareable(pipeline) }.not_to raise_error
    end

    it "stays shareable when a live model is named too -- the quote never rides along" do
      pipeline = scheduler(hard_cap: 100, model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, ran_under: "claude-opus-4-8"
      )

      expect(pipeline).to be_deeply_frozen
    end

    it "survives being stored in a Context via the injected-pipeline seam" do
      context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, pipeline: shared_pipeline)

      expect(context).to be_deeply_frozen
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
