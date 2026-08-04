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

RSpec.describe "Compaction journaling" do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  # A deterministic, pure, SHAREABLE summarizer -- the Compact contract. Six
  # substantial messages, keep_last(2), threshold 5: enough that a scheduled
  # compaction actually rewrites the head, so tokens_before/tokens_after
  # measure a real reduction rather than a no-op.
  let(:compact) do
    Lain::Context::Compact.new(threshold: 5, keep_last: 2, summarizer: JournalingShareableFixtures::SUMMARIZER)
  end
  let(:base) { JournalingShareableFixtures::BASE }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  def history(size = 6)
    (1...(size + 1)).map do |i|
      { "role" => "user", "content" => [{ "type" => "text", "text" => "the quick brown fox number #{i}" }] }
    end
  end

  def need(*signals) = Lain::Compaction::Need::Result.new(signals:)

  # T17. #pipeline is handed a MEASUREMENT rather than a message list -- the
  # floor deciding whether the rewrite is worth making took it already, and the
  # accounting reports that one measurement instead of retaking it -- so a spec
  # wanting a real before/after asks the SAME scheduler to measure the history
  # it is about to schedule.
  def scheduling(need:, cold:, history_size:, ran_under: nil, **built)
    scheduler(**built).then do |sched|
      sched.pipeline(need:, cold:, history_size:, base:, rewrite: sched.measure(history), ran_under:)
    end
  end

  def scheduler(hard_cap: 1_000_000, model: nil, price_book: Lain::PriceBook.default)
    Lain::Compaction::Scheduler.new(compact:, hard_cap:, journal:, model:, price_book:)
  end

  describe "a compacting decision journals its full accounting" do
    it "carries trigger, cache-state, tokens before/after, and cost saved vs spent" do
      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                 model: "claude-sonnet-4-6")

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
      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                 model: "claude-sonnet-4-6")

      record = records.first
      delta = BigDecimal(record["cost_saved"]) - BigDecimal(record["cost_spent"])
      expect(delta).to be_a(BigDecimal)
    end

    it "prices a forced-warm rewrite's message-tier cache write as cost_spent" do
      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                 model: "claude-sonnet-4-6")

      record = records.first
      expected_spent = Lain::PriceBook.default.cost(
        "claude-sonnet-4-6", Lain::Usage.new(cache_creation_input_tokens: record["tokens_after"])
      )
      expect(BigDecimal(record["cost_spent"])).to eq(expected_spent)
    end

    it "a cold compaction runs for free -- cost_spent is zero, matching the scheduler's own rationale" do
      scheduling(need: need(:token_threshold), cold: true, history_size: 10, model: "claude-sonnet-4-6")

      record = records.first
      expect(record["cache_state"]).to eq("cold")
      expect(BigDecimal(record["cost_spent"])).to eq(BigDecimal(0))
      expect(BigDecimal(record["cost_saved"])).to be > BigDecimal(0)
    end

    it "journals zero cost, not a raise, when the scheduler carries no model" do
      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100)

      record = records.first
      expect(BigDecimal(record["cost_saved"])).to eq(BigDecimal(0))
      expect(BigDecimal(record["cost_spent"])).to eq(BigDecimal(0))
    end

    it "a deferring decision journals nothing -- a non-compacting turn stays silent" do
      scheduling(need: need(:token_threshold), cold: false, history_size: 10)

      expect(records).to be_empty
    end

    it "approaching-window is one of the Need signals a forced compaction can carry as trigger" do
      scheduling(need: need(:approaching_window), cold: false, history_size: 10)

      expect(records.first["trigger"]).to eq(["approaching_window"])
    end

    # A8's review (Schneeman): without this, a compaction priced through a
    # ZERO fallback -- what an unpriced local model gets -- is byte-identical
    # on the record to a genuinely free one, and the only recovery is a join
    # against TurnUsage. That join is not merely inconvenient, it is WRONG
    # after a `/model` switch: the Source is built once and prices in the
    # model that was in force THEN, while TurnUsage names the model that
    # actually ran. Naming the tier here is what lets a reader see the
    # mismatch instead of being lied to about the dollars.
    it "names the model its cost figures are quoted in" do
      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                 model: "claude-sonnet-4-6")

      expect(records.first["model"]).to eq("claude-sonnet-4-6")
    end

    it "journals a nil model beside its zero costs, so an unpriced run says so" do
      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100)

      expect(records.first).to include("model" => nil, "cost_saved" => "0.0", "cost_spent" => "0.0")
    end
  end

  # C2. The scheduler's priced `model:` is fixed at construction; the model in
  # force is not (`/model` writes into Context::ModelSwitch's slot mid-session).
  # C1 made the compaction WINDOW follow the live model each turn and left the
  # price lookup behind, so after a switch the two halves disagreed. A figure
  # that cannot be stood behind is not emitted -- price_book.rb:112's doctrine,
  # one tier up.
  describe "a compaction priced against a model that is no longer in force" do
    def compacting(model:, ran_under:)
      built = scheduler(hard_cap: 100, model:)
      built.pipeline(
        need: need(:token_threshold), cold: false, history_size: 100, base:,
        rewrite: built.measure(history), ran_under:
      )
      records.first
    end

    it "quotes real figures, named in that model, when the priced model is the one that ran" do
      record = compacting(model: "claude-sonnet-4-6", ran_under: "claude-sonnet-4-6")

      expect(BigDecimal(record["cost_saved"])).to be > BigDecimal(0)
      expect(BigDecimal(record["cost_spent"])).to be > BigDecimal(0)
      expect(record["model"]).to eq("claude-sonnet-4-6")
    end

    it "quotes NOTHING once the run has switched models -- absent, not fabricated" do
      record = compacting(model: "claude-sonnet-4-6", ran_under: "claude-opus-4-8")

      expect(record["cost_saved"]).to be_nil
      expect(record["cost_spent"]).to be_nil
    end

    it "still names the model the compaction actually ran under" do
      record = compacting(model: "claude-sonnet-4-6", ran_under: "claude-opus-4-8")

      expect(record["model"]).to eq("claude-opus-4-8")
    end

    # The whole point of absence over zero: `cost_spent` already zeroes
    # LEGITIMATELY on a cold cache, so a switched run reporting zero would be
    # indistinguishable from a compaction that genuinely ran for free.
    it "is distinguishable from the real zero a cold compaction reports" do
      scheduling(need: need(:token_threshold), cold: true, history_size: 10, ran_under: "claude-sonnet-4-6",
                 model: "claude-sonnet-4-6")
      compacting(model: "claude-sonnet-4-6", ran_under: "claude-opus-4-8")
      free, refused = records

      expect(free["cost_spent"]).to eq("0.0")
      expect(refused["cost_spent"]).to be_nil
    end

    # nil-model and switched-model are DIFFERENT states. An unpriced scheduler
    # never quoted anything to invalidate, so it keeps journalling the zeros
    # {Telemetry::Compaction}'s header documents as a legitimate configuration.
    it "leaves the unpriced configuration alone -- zeros beside a nil model, not absence" do
      record = compacting(model: nil, ran_under: "claude-opus-4-8")

      expect(record).to include("model" => nil, "cost_saved" => "0.0", "cost_spent" => "0.0")
    end

    # A caller that names no live model contradicts nothing: absence of
    # information is not a mismatch, so the record is what it always was.
    it "quotes the priced figures when no live model is named at all" do
      record = compacting(model: "claude-sonnet-4-6", ran_under: nil)

      expect(BigDecimal(record["cost_saved"])).to be > BigDecimal(0)
      expect(record["model"]).to eq("claude-sonnet-4-6")
    end

    it "compares a Symbol live model against the priced String rather than mismatching on class" do
      record = compacting(model: "claude-sonnet-4-6", ran_under: :"claude-sonnet-4-6")

      expect(BigDecimal(record["cost_spent"])).to be > BigDecimal(0)
    end
  end

  # The decision is made on BYTES and cache warmth; pricing is an annotation on
  # a decision already taken. A pricing outcome that moved it would be a bench
  # measuring its own accounting.
  describe "pricing never moves the compact-or-defer decision" do
    def rendered(pipeline, messages)
      pipeline.call(Lain::Workspace.empty).call(messages)
    end

    it "renders byte-identically whether the quote is honoured or refused" do
      honoured = scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                            ran_under: "claude-sonnet-4-6", model: "claude-sonnet-4-6")
      refused = scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                           ran_under: "claude-opus-4-8", model: "claude-sonnet-4-6")

      expect(Lain::Canonical.dump(rendered(refused, history)))
        .to eq(Lain::Canonical.dump(rendered(honoured, history)))
    end

    it "still hands the base back UNTOUCHED when it defers, whatever the models say" do
      pipeline = scheduling(need: need(:token_threshold), cold: false, history_size: 10, model: "claude-sonnet-4-6",
                            ran_under: "claude-opus-4-8")

      expect(pipeline).to equal(base)
      expect(records).to be_empty
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

    # Additive: `model:` defaults, so every constructor that predates it --
    # this file's own subject included -- keeps working and reads as the
    # unpriced configuration the record already documented.
    it "defaults the model to nil, which is the unpriced configuration it always allowed" do
      expect(compaction.model).to be_nil
      expect(compaction.to_journal).to include("model" => nil)
    end

    it "holds the model as a frozen String and stays Ractor-shareable with one" do
      priced = described_class.new(
        trigger: %i[token_threshold], cache_state: :forced, tokens_before: 100, tokens_after: 40,
        cost_saved: 0, cost_spent: 0, model: +"claude-opus-4-8"
      )

      expect(priced.model).to eq("claude-opus-4-8")
      expect(priced).to be_deeply_frozen
      expect(JSON.parse(JSON.generate(priced.to_journal))).to include("model" => "claude-opus-4-8")
    end

    # C2. nil is REFUSAL -- "no figure we can stand behind" -- and the record
    # keeps the keys so a reader sees the field exists and carries nothing,
    # which `"0.0"` could never say.
    describe "a record that quotes no figures" do
      subject(:refused) do
        described_class.new(
          trigger: %i[token_threshold], cache_state: :forced, tokens_before: 100, tokens_after: 40,
          cost_saved: nil, cost_spent: nil, model: "claude-opus-4-8"
        )
      end

      it "journals both cost fields as null, distinguishable from a real zero" do
        round_tripped = JSON.parse(JSON.generate(refused.to_journal))

        expect(round_tripped).to include("cost_saved" => nil, "cost_spent" => nil,
                                         "model" => "claude-opus-4-8")
        expect(round_tripped["cost_saved"]).not_to eq("0.0")
      end

      it "says so, so a consumer never has to probe two fields to find out" do
        expect(refused).not_to be_priced
        expect(compaction).to be_priced
      end

      it "has no cost delta to offer, rather than a zero one" do
        expect(refused.cost_delta).to be_nil
      end

      # DELIBERATE, not incidental. A zero here would let a Compare-style
      # consumer fold a refusal into a total as "this compaction broke even",
      # which is precisely the quiet wrong number this record exists to
      # prevent. nil makes the same fold raise, at the row that cannot be
      # priced, naming the arithmetic rather than the record.
      it "makes a consumer that sums deltas fail LOUDLY rather than under-count" do
        expect { [compaction, refused].sum(&:cost_delta) }.to raise_error(TypeError)
        expect([compaction, refused].select(&:priced?).sum(&:cost_delta)).to eq(compaction.cost_delta)
      end

      it "stays a frozen, Ractor-shareable value object" do
        expect(refused).to be_deeply_frozen
      end

      # Panel probe 2F, promoted. nil is the ONLY refusal; `false` is not a
      # decimal and never was -- before this card `BigDecimal("false")` raised,
      # and the `value && ...` short-circuit that let nil through would have
      # let `false` through too, storing a JSON boolean in a money field and
      # answering `priced?` true about it.
      it "refuses a `false` cost -- nil is the refusal, and nothing else is" do
        expect do
          described_class.new(trigger: %i[manual], cache_state: :cold, tokens_before: 1, tokens_after: 1,
                              cost_saved: false, cost_spent: false)
        end.to raise_error(ArgumentError, /BigDecimal/)
      end

      it "refuses to quote one figure without the other -- absence is a property of the record" do
        expect do
          described_class.new(trigger: %i[manual], cache_state: :cold, tokens_before: 1, tokens_after: 1,
                              cost_saved: 0, cost_spent: nil)
        end.to raise_error(ArgumentError, /cost_saved/)
      end
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
      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                 model: "claude-sonnet-4-6")

      lines = journal_io.string.each_line.to_a
      expect(lines.size).to eq(1)
      expect { JSON.parse(lines.first) }.not_to raise_error
    end

    it "does not disturb an existing Verdict record already on the journal" do
      journal << Lain::Telemetry::Verdict.new(digest: "abc", survived: true, score: 0.9, why: "matched")

      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                 model: "claude-sonnet-4-6")

      expect(records.map { |r| r["type"] }).to eq(%w[verdict compaction])
      expect(records.first).to include("digest" => "abc", "survived" => true)
    end

    it "does not disturb an existing OracleAnswer record already on the journal" do
      journal << Lain::Telemetry::OracleAnswer.new(oracle_digest: "def", question: "q?", answer: { "a" => 1 })

      scheduling(need: need(:token_threshold), cold: false, history_size: 100, hard_cap: 100,
                 model: "claude-sonnet-4-6")

      expect(records.map { |r| r["type"] }).to eq(%w[oracle_answer compaction])
    end
  end
end
