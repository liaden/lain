# frozen_string_literal: true

require "bigdecimal"

require "lain/ledger"
require "lain/timeline"
require "lain/store"
require "lain/usage"

RSpec.describe Lain::Ledger do
  subject(:ledger) { described_class.new }

  let(:store) { Lain::Store.new }
  let(:model) { "claude-sonnet-4" }

  # 10 in, 5 out -> $0.00003 + $0.000075 = $0.000105 per turn under sonnet.
  def usage_meta
    { usage: { input_tokens: 10, output_tokens: 5,
               cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
      model: model }
  end

  def commit(timeline, text, meta: usage_meta)
    timeline.commit(role: "assistant", content: [{ type: "text", text: text }], meta: meta)
  end

  describe "a single chain" do
    it "sums usage over its turns" do
      timeline = commit(commit(Lain::Timeline.empty(store: store), "a"), "b")
      expect(ledger.usage(timeline).total_tokens).to eq(30)
    end

    it "ignores turns that carry no usage (user turns are free)" do
      timeline = Lain::Timeline.empty(store: store)
                               .commit(role: "user", content: [{ type: "text", text: "hi" }])
      expect(ledger.usage(timeline)).to eq(Lain::Usage.zero)
      expect(ledger.cost(timeline)).to eq(BigDecimal(0))
    end
  end

  # THE payoff of structural bet #1, and the trap it exists to avoid: two branches
  # share a prefix, and naive summing counts that prefix once per branch.
  describe "a FORKED timeline" do
    let(:root) { commit(commit(Lain::Timeline.empty(store: store), "shared-1"), "shared-2") }
    let(:branch_a) { commit(root, "only-a") }
    let(:branch_b) { commit(root, "only-b") }

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

  describe "mixed models" do
    it "prices each turn against its own model" do
      timeline = Lain::Timeline.empty(store: store)
      timeline = commit(timeline, "sonnet-turn")
      timeline = commit(timeline, "haiku-turn", meta: {
                          usage: { input_tokens: 1_000_000, output_tokens: 0,
                                   cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
                          model: "claude-haiku-3-5"
                        })
      # sonnet: $0.000105; haiku: 1M input * $0.8/M = $0.80.
      expect(ledger.cost(timeline)).to eq(BigDecimal("0.000105") + BigDecimal("0.8"))
    end
  end

  describe "#per_turn" do
    it "yields one priced record per unique reachable turn" do
      root = commit(commit(Lain::Timeline.empty(store: store), "s1"), "s2")
      records = ledger.per_turn(commit(root, "a"), commit(root, "b"))
      expect(records.size).to eq(4)
      expect(records.map { |r| r["digest"] }.uniq.size).to eq(4)
      expect(records.first).to include("cost", "usage", "model" => model)
    end
  end
end
