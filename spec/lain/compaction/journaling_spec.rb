# frozen_string_literal: true

require "json"
require "stringio"
require "bigdecimal"

# Shareable fixtures, the same reason SchedulerShareableFixtures exists in
# scheduler_spec.rb: the scheduler makes the pipeline it composes shareable,
# so the injected compact/base it closes over must already be shareable --
# see COMPOSE's comment in scheduler.rb. Defined fresh here rather than
# reused from scheduler_spec.rb so this file's examples never depend on
# cross-file spec LOAD ORDER for a constant to exist.
module JournalingShareableFixtures
  SUMMARIZER = Ractor.make_shareable(->(_dropped) { "SUMMARY" })
  BASE = Ractor.make_shareable(->(_workspace) { Lain::Context::Identity })
end

RSpec.describe "Compaction journaling (T20/CAC-6)" do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  # A deterministic, pure, SHAREABLE summarizer -- the Compact contract. Six
  # substantial messages, keep_last(2), threshold 5: enough that a scheduled
  # compaction actually rewrites the head, so tokens_before/tokens_after
  # measure a real reduction rather than a no-op.
  let(:compact) do
    Lain::Context::Compact.new(threshold: 5, keep_last: 2, summarizer: JournalingShareableFixtures::SUMMARIZER)
  end
  let(:base) { JournalingShareableFixtures::BASE }

  def history(size = 6)
    (1...(size + 1)).map do |i|
      { "role" => "user", "content" => [{ "type" => "text", "text" => "the quick brown fox number #{i}" }] }
    end
  end

  def need(*signals) = Lain::Compaction::Need::Result.new(signals:)

  def scheduler(hard_cap: 1_000_000, model: nil, price_book: Lain::PriceBook.default)
    Lain::Compaction::Scheduler.new(compact:, hard_cap:, journal:, model:, price_book:)
  end

  describe "a compacting decision journals its full accounting" do
    it "carries trigger, cache-state, tokens before/after, and cost saved vs spent" do
      scheduler(hard_cap: 100, model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, messages: history
      )

      expect(records.size).to eq(1)
      record = records.first
      expect(record["type"]).to eq("compaction")
      expect(record["trigger"]).to eq(["token_threshold"])
      expect(record["cache_state"]).to eq("forced")
      expect(record["tokens_before"]).to be > record["tokens_after"]
      expect(BigDecimal(record["cost_saved"])).to be > BigDecimal(0)
      expect(BigDecimal(record["cost_spent"])).to be > BigDecimal(0)
    end

    it "Compare can read the cost delta attributed to the policy" do
      scheduler(hard_cap: 100, model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, messages: history
      )

      record = records.first
      delta = BigDecimal(record["cost_saved"]) - BigDecimal(record["cost_spent"])
      expect(delta).to be_a(BigDecimal)
    end

    it "prices a forced-warm rewrite's message-tier cache write as cost_spent" do
      scheduler(hard_cap: 100, model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, messages: history
      )

      record = records.first
      expected_spent = Lain::PriceBook.default.cost(
        "claude-sonnet-4-6", Lain::Usage.new(cache_creation_input_tokens: record["tokens_after"])
      )
      expect(BigDecimal(record["cost_spent"])).to eq(expected_spent)
    end

    it "a cold compaction runs for free -- cost_spent is zero, matching the scheduler's own rationale" do
      scheduler(model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: true, history_size: 10, base:, messages: history
      )

      record = records.first
      expect(record["cache_state"]).to eq("cold")
      expect(BigDecimal(record["cost_spent"])).to eq(BigDecimal(0))
      expect(BigDecimal(record["cost_saved"])).to be > BigDecimal(0)
    end

    it "journals zero cost, not a raise, when the scheduler carries no model" do
      scheduler(hard_cap: 100).pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, messages: history
      )

      record = records.first
      expect(BigDecimal(record["cost_saved"])).to eq(BigDecimal(0))
      expect(BigDecimal(record["cost_spent"])).to eq(BigDecimal(0))
    end

    it "a deferring decision journals nothing -- a non-compacting turn stays silent" do
      scheduler.pipeline(need: need(:token_threshold), cold: false, history_size: 10, base:, messages: history)

      expect(records).to be_empty
    end

    it "approaching-window is one of the Need signals a forced compaction can carry as trigger" do
      scheduler.pipeline(need: need(:approaching_window), cold: false, history_size: 10, base:, messages: history)

      expect(records.first["trigger"]).to eq(["approaching_window"])
    end
  end

  describe Lain::Telemetry::Compaction do
    subject(:compaction) do
      described_class.new(
        trigger: %i[token_threshold], cache_state: :forced, tokens_before: 100, tokens_after: 40,
        cost_saved: BigDecimal("0.002"), cost_spent: BigDecimal("0.0005")
      )
    end

    it "is a frozen, Ractor-shareable value object" do
      expect(compaction).to be_deeply_frozen
      expect(compaction).to be_ractor_shareable
    end

    it "journals as a compaction record that round-trips through JSON" do
      expect(compaction.to_journal).to include(
        "type" => "compaction", "trigger" => %i[token_threshold], "cache_state" => :forced,
        "tokens_before" => 100, "tokens_after" => 40
      )
      round_tripped = JSON.parse(JSON.generate(compaction.to_journal))
      expect(round_tripped).to include(
        "type" => "compaction", "trigger" => ["token_threshold"], "cache_state" => "forced",
        "tokens_before" => 100, "tokens_after" => 40, "cost_saved" => "0.002", "cost_spent" => "0.0005"
      )
    end

    it "computes the cost delta Compare attributes to the scheduling policy" do
      expect(compaction.cost_delta).to eq(BigDecimal("0.0015"))
    end

    it "rejects an empty trigger -- a compaction record must name what fired it" do
      expect do
        described_class.new(trigger: [], cache_state: :cold, tokens_before: 1, tokens_after: 1,
                            cost_saved: 0, cost_spent: 0)
      end.to raise_error(ArgumentError, /trigger/)
    end

    it "rejects a cache_state outside warm/cold/forced" do
      expect do
        described_class.new(trigger: %i[manual], cache_state: :lukewarm, tokens_before: 1, tokens_after: 1,
                            cost_saved: 0, cost_spent: 0)
      end.to raise_error(ArgumentError, /cache_state/)
    end

    it "accepts a String cache_state (JSON never round-trips Symbols) equal to the Symbol form" do
      from_string = described_class.new(
        trigger: %i[token_threshold], cache_state: "forced", tokens_before: 100, tokens_after: 40,
        cost_saved: 0, cost_spent: 0
      )

      expect(from_string.cache_state).to eq(:forced)
    end
  end

  describe "NDJSON discipline (a stray write corrupts the experiment record)" do
    it "journals the compaction as exactly one JSON object per line" do
      scheduler(hard_cap: 100, model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, messages: history
      )

      lines = journal_io.string.each_line.to_a
      expect(lines.size).to eq(1)
      expect { JSON.parse(lines.first) }.not_to raise_error
    end

    it "does not disturb an existing Verdict record already on the journal" do
      journal << Lain::Telemetry::Verdict.new(digest: "abc", survived: true, score: 0.9, why: "matched")

      scheduler(hard_cap: 100, model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, messages: history
      )

      expect(records.map { |r| r["type"] }).to eq(%w[verdict compaction])
      expect(records.first).to include("digest" => "abc", "survived" => true)
    end

    it "does not disturb an existing OracleAnswer record already on the journal" do
      journal << Lain::Telemetry::OracleAnswer.new(oracle_digest: "def", question: "q?", answer: { "a" => 1 })

      scheduler(hard_cap: 100, model: "claude-sonnet-4-6").pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:, messages: history
      )

      expect(records.map { |r| r["type"] }).to eq(%w[oracle_answer compaction])
    end
  end
end
