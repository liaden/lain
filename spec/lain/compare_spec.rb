# frozen_string_literal: true

require "lain/compare"

require "lain/usage"
require "lain/capability/degraded_set"
require "lain/capability/guard"
require "lain/grader"
require "lain/timeline"
require "lain/store"

# Compare draws DISTRIBUTIONS over n>=2 runs -- a single A/B is noise -- and
# refuses, loudly, to compare runs that degraded different capabilities (a
# cross-arm comparison where half the tactics silently no-oped on one side is a
# lie, not a result). Its report is a DX artifact: a scannable per-metric table,
# never a wall of floats.
RSpec.describe Lain::Compare do
  def usage(input:, output:, cache_read: 0)
    Lain::Usage.new(input_tokens: input, output_tokens: output, cache_read_input_tokens: cache_read)
  end

  def run(name, usage:, cost:, score: nil, degraded: Lain::Capability::DegradedSet.new([]))
    Lain::Compare::Run.new(name: name, usage: usage, cost: BigDecimal(cost.to_s), score: score, degraded: degraded)
  end

  let(:runs) do
    [
      run("a", usage: usage(input: 900, output: 100, cache_read: 400), cost: "0.0030", score: 1.0),
      run("b", usage: usage(input: 1000, output: 150, cache_read: 500), cost: "0.0040", score: 0.5),
      run("c", usage: usage(input: 1100, output: 200, cache_read: 300), cost: "0.0035", score: 1.0)
    ]
  end

  it "requires at least two runs -- one run is not a distribution" do
    expect { described_class.new([runs.first]) }.to raise_error(ArgumentError, /two|distribution/i)
  end

  describe "the capability guard" do
    it "refuses to compare runs whose degraded sets differ" do
      mixed = [
        run("thinks", usage: usage(input: 10, output: 1), cost: "0.001",
                      degraded: Lain::Capability::DegradedSet.new([])),
        run("degraded", usage: usage(input: 10, output: 1), cost: "0.001",
                        degraded: Lain::Capability::DegradedSet.new(%i[thinking]))
      ]
      expect { described_class.new(mixed) }.to raise_error(Lain::Capability::Guard::Mismatch)
    end

    it "compares happily when every run degraded the same capabilities" do
      same = Array.new(2) do |i|
        run("r#{i}", usage: usage(input: 10, output: 1), cost: "0.001",
                     degraded: Lain::Capability::DegradedSet.new(%i[thinking]))
      end
      expect { described_class.new(same) }.not_to raise_error
    end
  end

  describe "distributions" do
    let(:compare) { described_class.new(runs) }

    it "aggregates total tokens across runs (cache reads count -- they were billed)" do
      dist = compare.distribution(:total_tokens)
      # totals (input + cache_read + output): 1400, 1650, 1600
      expect(dist.mean).to eq(1550.0)
      expect(dist.median).to eq(1600.0)
      expect(dist.min).to eq(1400.0)
      expect(dist.max).to eq(1650.0)
    end

    it "aggregates the grader score" do
      dist = compare.distribution(:score)
      expect(dist.mean).to be_within(1e-9).of((1.0 + 0.5 + 1.0) / 3)
      expect(dist.median).to eq(1.0)
    end

    it "keeps cost in BigDecimal so it does not drift" do
      dist = compare.distribution(:cost)
      expect(dist.mean).to be_a(BigDecimal)
      expect(dist.mean).to eq(BigDecimal("0.0035"))
    end
  end

  describe "#report" do
    let(:report) { described_class.new(runs).report }

    it "returns a String, never touching stdout" do
      expect(report).to be_a(String)
    end

    it "is a scannable table: one labelled row per metric with mean/median/min/max" do
      ["total tokens", "cache hit", "cost", "score"].each do |label|
        expect(report.downcase).to include(label)
      end
      expect(report).to include("mean")
      expect(report).to include("median")
    end

    it "states how many runs and which capabilities degraded" do
      expect(report).to match(/3 runs/)
    end

    it "omits the score row when not every run was graded" do
      ungraded = runs.map do |r|
        described_class::Run.new(name: r.name, usage: r.usage, cost: r.cost, degraded: r.degraded)
      end
      expect(described_class.new(ungraded).report.downcase).not_to include("score")
    end
  end

  describe "Run.from_timeline" do
    it "derives usage and cost from a recorded Timeline via the Ledger" do
      store = Lain::Store.new
      timeline = Lain::Timeline.empty(store: store)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }],
                                       meta: { "model" => "claude-sonnet-4", "usage" => { "input_tokens" => 1000,
                                                                                          "output_tokens" => 200 } })
      run = described_class::Run.from_timeline(name: "recorded", timeline: timeline,
                                               grade: Lain::Grader::Grade.new(score: 1.0, why: "ok"))
      expect(run.total_tokens).to eq(1200)
      expect(run.cost).to be > 0
      expect(run.score).to eq(1.0)
    end
  end
end
