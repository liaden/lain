# frozen_string_literal: true

require "bigdecimal"
require "json"

RSpec.describe Lain::Ledger do
  let(:store) { Lain::Store.new }
  let(:model) { "claude-sonnet-4" }
  let(:records) { [] }

  # Built on demand (a method, not a let) so the Index sees every record the
  # example has journaled by the time the ledger is asked.
  def ledger
    described_class.from_journal(records)
  end

  # 10 in, 5 out -> $0.00003 + $0.000075 = $0.000105 per turn under sonnet.
  def turn_usage(input: 10, output: 5)
    { "input_tokens" => input, "output_tokens" => output,
      "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 }
  end

  # Commit an assistant turn and journal its payment the way Agent::Accounting
  # does: usage rides in the Journal, never in the turn's meta.
  def commit(timeline, text, model: self.model, usage: turn_usage)
    committed = timeline.commit(role: "assistant", content: [{ type: "text", text: }])
    records << { "type" => "turn_usage", "digest" => committed.head_digest,
                 "model" => model, "stop_reason" => "end_turn", "usage" => usage }
    committed
  end

  describe "construction" do
    it "demands a usage source: no index, no Ledger" do
      expect { described_class.new }.to raise_error(ArgumentError, /index/)
    end

    it "builds from raw NDJSON lines via .from_journal" do
      timeline = commit(Lain::Timeline.empty(store:), "a")
      lines = records.map { |record| JSON.generate(record) }
      expect(described_class.from_journal(lines).usage(timeline).total_tokens).to eq(15)
    end
  end

  describe "a single chain" do
    it "sums usage over its turns" do
      timeline = commit(commit(Lain::Timeline.empty(store:), "a"), "b")
      expect(ledger.usage(timeline).total_tokens).to eq(30)
    end

    it "ignores turns absent from the index (user turns are free)" do
      timeline = Lain::Timeline.empty(store:)
                               .commit(role: "user", content: [{ type: "text", text: "hi" }])
      expect(ledger.usage(timeline)).to eq(Lain::Usage.zero)
      expect(ledger.cost(timeline)).to eq(BigDecimal(0))
    end
  end

  # THE payoff of structural bet #1, and the trap it exists to avoid: two branches
  # share a prefix, and naive summing counts that prefix once per branch.
  describe "a FORKED timeline" do
    let(:root) { commit(commit(Lain::Timeline.empty(store:), "shared-1"), "shared-2") }
    let(:branch_a) { commit(root, "only-a") }
    let(:branch_b) { commit(root, "only-b") }

    before do
      branch_a
      branch_b
    end

    it "counts the shared prefix exactly once" do
      # 4 unique assistant turns: shared-1, shared-2, only-a, only-b.
      expect(ledger.usage(branch_a, branch_b).total_tokens).to eq(4 * 15)
    end

    it "is strictly less than the naive per-branch sum" do
      naive = ledger.usage(branch_a).total_tokens + ledger.usage(branch_b).total_tokens
      unique = ledger.usage(branch_a, branch_b).total_tokens
      # naive double-counts the 2 shared turns; unique does not.
      expect(unique).to eq(naive - (2 * 15))
      expect(unique).to be < naive
    end

    it "counts dollar cost over unique digests too" do
      # 4 unique turns x $0.000105.
      expect(ledger.cost(branch_a, branch_b)).to eq(BigDecimal("0.00042"))
    end

    it "is independent of the order the branches are given" do
      expect(ledger.usage(branch_a, branch_b)).to eq(ledger.usage(branch_b, branch_a))
      expect(ledger.cost(branch_a, branch_b)).to eq(ledger.cost(branch_b, branch_a))
    end

    it "accepts branches as a nested array too" do
      expect(ledger.usage([branch_a, branch_b]).total_tokens).to eq(4 * 15)
    end
  end

  # Content dedup (above) and payment aggregation (here) are different
  # operations, and the Ledger does both (see Telemetry::TurnUsage).
  describe "duplicate digests are separate payments" do
    it "sums BOTH payments for a rewound-and-regenerated turn" do
      timeline = commit(Lain::Timeline.empty(store:), "same answer")
      records << records.last.dup
      expect(ledger.usage(timeline).total_tokens).to eq(30)
    end

    it "prices each payment against its own recorded model" do
      timeline = commit(Lain::Timeline.empty(store:), "same answer")
      records << records.last.merge("model" => "claude-haiku-3-5")
      # sonnet: $0.000105; haiku: 10 x $0.8/M + 5 x $4/M = $0.000028.
      expect(ledger.cost(timeline)).to eq(BigDecimal("0.000105") + BigDecimal("0.000028"))
    end

    # The two aggregations composed: content dedups across the fork while every
    # payment still counts. Two runs each regenerate the identical shared
    # prefix, then diverge -- 4 unique digests carrying 6 payments.
    it "sums a fork-shared prefix's content once but its regenerated payments all" do
      branch_a = commit(commit(commit(Lain::Timeline.empty(store:), "shared-1"), "shared-2"), "only-a")
      branch_b = commit(commit(commit(Lain::Timeline.empty(store:), "shared-1"), "shared-2"), "only-b")

      expect(ledger.usage(branch_a, branch_b).total_tokens).to eq(6 * 15)
      expect(ledger.cost(branch_a, branch_b)).to eq(BigDecimal("0.00063"))
    end
  end

  describe "mixed models" do
    it "prices each turn against its own model" do
      timeline = Lain::Timeline.empty(store:)
      timeline = commit(timeline, "sonnet-turn")
      timeline = commit(timeline, "haiku-turn", model: "claude-haiku-3-5",
                                                usage: turn_usage(input: 1_000_000, output: 0))
      # sonnet: $0.000105; haiku: 1M input * $0.8/M = $0.80.
      expect(ledger.cost(timeline)).to eq(BigDecimal("0.000105") + BigDecimal("0.8"))
    end
  end

  describe "a payment with no recorded model" do
    # The first error a mock-journal Compare user hits, so it must diagnose
    # itself: name the turn, say WHY the model is missing, name the way out.
    it "raises UnknownModel naming the digest, the provenance, and the fallback escape hatch" do
      timeline = commit(Lain::Timeline.empty(store:), "mock turn", model: nil)
      expect { ledger.cost(timeline) }.to raise_error(Lain::PriceBook::UnknownModel) do |error|
        expect(error.message).to include(timeline.head_digest)
        expect(error.message).to match(/recorded no model/i)
        expect(error.message).to match(/bare mock|un-instrumented/i)
        expect(error.message).to match(/fallback/i)
      end
    end

    it "prices through a PriceBook fallback, as the error advises" do
      timeline = commit(Lain::Timeline.empty(store:), "mock turn", model: nil)
      free = Lain::Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      priced = described_class.new(index: Lain::Ledger::Index.from_journal(records),
                                   price_book: Lain::PriceBook.new(fallback: free))
      expect(priced.cost(timeline)).to eq(BigDecimal(0))
    end

    it "still reports a genuinely unknown NAMED model with PriceBook's own message" do
      timeline = commit(Lain::Timeline.empty(store:), "who", model: "gpt-42")
      expect { ledger.cost(timeline) }
        .to raise_error(Lain::PriceBook::UnknownModel, /gpt-42/)
    end
  end
end
