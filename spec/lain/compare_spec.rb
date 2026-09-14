# frozen_string_literal: true

# Compare draws DISTRIBUTIONS over n>=2 runs -- a single A/B is noise -- and
# refuses, loudly, on the two axes that decide whether the runs were comparable
# at all: the capabilities they degraded (a cross-arm comparison where half the
# tactics silently no-oped on one side is a lie, not a result) and the posture
# they ran under (a plan-mode run never saw the editing tools). Both arrive as
# arguments a caller must thread, so both have a vacuous branch, and the posture
# describe below is where that branch is held shut. Its report is a DX artifact:
# a scannable per-metric table, never a wall of floats.
RSpec.describe Lain::Compare do
  def usage(input:, output:, cache_read: 0, cache_write: 0)
    Lain::Usage.new(input_tokens: input, output_tokens: output, cache_read_input_tokens: cache_read,
                    cache_creation_input_tokens: cache_write)
  end

  def run(name, usage:, cost:, score: nil, degraded: Lain::Capability::DegradedSet.new([]), posture: nil)
    Lain::Compare::Run.new(name:, usage:, price: Lain::Compare::Priced.new(amount: BigDecimal(cost.to_s)), score:,
                           degraded:, posture:)
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

    it "aggregates cache-write tokens across runs" do
      cache_write_runs = [
        run("a", usage: usage(input: 10, output: 1, cache_write: 50), cost: "0.001"),
        run("b", usage: usage(input: 10, output: 1, cache_write: 80), cost: "0.001"),
        run("c", usage: usage(input: 10, output: 1, cache_write: 20), cost: "0.001")
      ]
      dist = described_class.new(cache_write_runs).distribution(:cache_write_tokens)
      expect(dist.mean).to be_within(1e-9).of(50.0)
      expect(dist.median).to eq(50.0)
      expect(dist.min).to eq(20.0)
      expect(dist.max).to eq(80.0)
    end
  end

  # An Integer-valued metric must not floor: Integer#/ truncates, so the mean of
  # a sum not divisible by n has to come back a real fraction, not a lie the
  # "%.1f" format would dress up as precise.
  describe "Distribution does not floor Integer metrics" do
    it "means an odd-count Integer metric as a true fraction" do
      dist = described_class::Distribution.new([1000, 1000, 1001])
      expect(dist.mean).to be_within(1e-9).of(3001 / 3.0)
      expect(dist.median).to eq(1000)
    end

    it "means an even-count Integer metric across the two middle values" do
      dist = described_class::Distribution.new([1000, 1001])
      expect(dist.mean).to eq(1000.5)
      expect(dist.median).to eq(1000.5)
    end

    it "keeps BigDecimal cost exact even when it does not divide evenly" do
      dist = described_class::Distribution.new([BigDecimal("0.001"), BigDecimal("0.002")])
      expect(dist.mean).to be_a(BigDecimal)
      expect(dist.mean).to eq(BigDecimal("0.0015"))
    end
  end

  describe "value objects clear the Ractor.shareable? bar" do
    it "deeply freezes a Distribution" do
      expect(described_class::Distribution.new([1, 2, 3])).to be_deeply_frozen
    end

    it "deeply freezes a Run" do
      expect(runs.first).to be_deeply_frozen
    end
  end

  describe "#report" do
    let(:report) { described_class.new(runs).report }

    it "is a scannable table: one labelled row per metric with mean/median/min/max" do
      ["total tokens", "cache hit", "cost", "score", "cache write"].each do |label|
        expect(report.downcase).to include(label)
      end
      expect(report).to include("mean")
      expect(report).to include("median")
    end

    # Literal, never read off METRICS or ArmFold::HEADERS: an expectation sourced
    # from the constant it pins passes a reorder of that constant unchanged.
    # These two are the only literal pins on Compare's own rendered summary.
    it "heads the summary table with metric, n, mean, median, min and max" do
      header = report.lines.map(&:chomp).find { |line| line.start_with?("metric") }
      expect(header.split(/\s{2,}/)).to eq(%w[metric n mean median min max])
    end

    # Four DISTINCT values, so a mean/median or min/max transposition renders
    # four plausible numbers under the wrong headings -- which is precisely the
    # failure a whole green suite could not see before. Totals are 1400, 1650 and
    # 1600, so mean 1550.0, median 1600.0, min 1400.0, max 1650.0.
    it "puts each stat under its own column, in the declared order" do
      row = report.lines.map(&:chomp).find { |line| line.start_with?("total tokens") }
      expect(row.split(/\s{2,}/)).to eq(["total tokens", "3", "1550.0", "1600.0", "1400.0", "1650.0"])
    end

    # Pins ORDER, not just presence: METRICS is a Hash, so a mid-hash insertion of a
    # future metric between :score and :cache_write_tokens would satisfy every
    # "includes the label" assertion above while silently reordering columns. This
    # example is the one that would actually catch that regression.
    it "places cache-write immediately after grader score, keeping the existing four in place" do
      expect(described_class::METRICS.keys).to eq(%i[total_tokens cache_hit_ratio cost score cache_write_tokens])
    end

    it "states how many runs and which capabilities degraded" do
      expect(report).to include("3 runs")
    end

    it "omits the score row when not every run was graded" do
      ungraded = runs.map do |r|
        described_class::Run.new(name: r.name, usage: r.usage, price: r.price, degraded: r.degraded)
      end
      expect(described_class.new(ungraded).report.downcase).not_to include("score")
    end
  end

  describe "Run.from_timeline" do
    # A recorded run's usage lives in the Journal, not in turn meta, so a Run is
    # priced through a journal-sourced Ledger the caller must supply.
    def recorded(text, input:, output:, model: "claude-sonnet-4")
      timeline = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
      ledger = Lain::Ledger.from_journal([
                                           { "type" => "turn_usage", "digest" => timeline.head_digest,
                                             "model" => model, "stop_reason" => "end_turn",
                                             "usage" => { "input_tokens" => input, "output_tokens" => output } }
                                         ])
      [timeline, ledger]
    end

    it "derives usage and cost from a recorded Timeline via a journal-sourced Ledger" do
      timeline, ledger = recorded("yo", input: 1000, output: 200)
      run = described_class::Run.from_timeline(name: "recorded", timeline:, ledger:,
                                               grade: Lain::Grader::Grade.new(score: 1.0, why: "ok"))
      expect(run.total_tokens).to eq(1200)
      expect(run.cost).to be > 0
      expect(run.score).to eq(1.0)
    end

    it "has no default ledger: a Run must name its usage source" do
      expect { described_class::Run.from_timeline(name: "x", timeline: nil) }
        .to raise_error(ArgumentError, /ledger/)
    end

    it "carries the posture the caller recorded for the run" do
      timeline, ledger = recorded("yo", input: 10, output: 1)
      run = described_class::Run.from_timeline(name: "recorded", timeline:, ledger:, posture: :plan)
      expect(run.posture.to_s).to eq("plan")
    end
  end

  # A price book with no row for a model REFUSES rather than guessing, and the
  # Ledger keeps raising -- but refusing to name a price is not refusing to
  # compare. The tokens were still counted; only the dollar figure is unknowable,
  # so only the dollar figure is withheld, and it says why in the Ledger's words.
  describe "a run the price book cannot price" do
    def recorded_run(name, model:)
      timeline = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: [{ "type" => "text", "text" => name }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "done" }])
      ledger = Lain::Ledger.from_journal([{ "type" => "turn_usage", "digest" => timeline.head_digest,
                                            "model" => model, "usage" => { "input_tokens" => 100,
                                                                           "output_tokens" => 20 } }])
      described_class::Run.from_timeline(name:, timeline:, ledger:)
    end

    let(:unpriced) { [recorded_run("a", model: "qwen3:4b"), recorded_run("b", model: "qwen3:4b")] }
    let(:report) { described_class.new(unpriced).report }

    it "builds from a timeline without raising, carrying the ledger's reason instead of a cost" do
      run = recorded_run("local", model: "qwen3:4b")
      expect(run.price).to be_refuses
      expect(run.price.reason).to include("qwen3:4b").and include("fallback")
    end

    # Never a zero: a caller that asks for the number anyway gets the Ledger's
    # refusal back, not a figure it could mistake for "free".
    it "raises the ledger's refusal when its cost is read as a number" do
      expect { recorded_run("local", model: "qwen3:4b").cost }
        .to raise_error(Lain::PriceBook::UnknownModel, /qwen3:4b/)
    end

    it "keeps an unpriced run deeply frozen" do
      expect(unpriced.first).to be_deeply_frozen
    end

    it "still reports total tokens" do
      row = report.lines.map(&:chomp).find { |line| line.start_with?("total tokens") }
      expect(row.split(/\s{2,}/)).to eq(["total tokens", "2", "120.0", "120.0", "120.0", "120.0"])
    end

    it "withholds the cost row, saying not priced with the ledger's reason, never 0.000000" do
      expect(report).to include(%(cost (USD): not priced — no price for model "qwen3:4b"))
      expect(report).not_to include("0.000000")
      expect(report.lines.grep(/\Acost \(USD\)\s{2,}/)).to be_empty
    end

    it "withholds the cost column from the per-run appendix" do
      appendix_header = report.lines.map(&:chomp).find { |line| line.start_with?("run ") }
      expect(appendix_header).not_to include("cost")
    end

    # One unknowable figure makes the whole distribution unknowable: a mean over
    # the priced subset would silently compare different populations, the same
    # reason score is withheld unless every run was graded.
    it "withholds cost when any single run is unpriced" do
      mixed = [recorded_run("priced", model: "claude-sonnet-4"), recorded_run("local", model: "qwen3:4b")]
      expect(described_class.new(mixed).report).to include("cost (USD): not priced —")
    end

    it "names each distinct reason once" do
      mixed = [recorded_run("a", model: "qwen3:4b"), recorded_run("b", model: "qwen3:4b"),
               recorded_run("c", model: "llama3")]
      line = described_class.new(mixed).report.lines.find { |candidate| candidate.start_with?("cost (USD):") }
      expect(line.scan("qwen3:4b").size).to eq(1)
      expect(line).to include("llama3")
    end

    it "refuses to draw the cost distribution rather than fold a zero" do
      expect { described_class.new(unpriced).distribution(:cost) }
        .to raise_error(Lain::PriceBook::UnknownModel)
    end

    it "leaves a fully priced report free of any withheld line" do
      expect(described_class.new(runs).report).not_to include("not priced")
    end
  end

  # A provider without prompt caching journals the degradation, and every cache
  # read it reports is then a zero that was never measured. A cache hit ratio of
  # 0.000 over such runs reads as "the cache went cold", which is not what
  # happened: there was no cache.
  describe "a cacheless provider" do
    def degraded_runs(*capabilities)
      degraded = Lain::Capability::DegradedSet.new(capabilities)
      Array.new(2) { |i| run("r#{i}", usage: usage(input: 10, output: 1), cost: "0.001", degraded:) }
    end

    let(:report) { described_class.new(degraded_runs(:prompt_caching)).report }

    it "shows no cache hit ratio row in the summary" do
      expect(report.lines.grep(/\Acache hit ratio\s{2,}/)).to be_empty
    end

    it "shows no cache hit ratio column in the per-run appendix" do
      appendix_header = report.lines.map(&:chomp).find { |line| line.start_with?("run ") }
      expect(appendix_header).not_to include("cache hit ratio")
    end

    it "says why the ratio is withheld" do
      expect(report).to include("cache hit ratio: not measured — every run records prompt_caching degraded")
    end

    it "keeps the ratio when the runs degraded some other capability" do
      expect(described_class.new(degraded_runs(:thinking)).report.lines.grep(/\Acache hit ratio\s{2,}/))
        .not_to be_empty
    end
  end

  # The posture is an AXIS, not decoration. Compare already refuses to draw a
  # distribution across runs that degraded different capabilities; a `plan` run
  # against an `auto` run is the same kind of apples-to-oranges, because the
  # posture decides which tools the model could even see and which calls a human
  # had to answer. The case that must not break is ABSENCE: every recording made
  # before modes existed carries no mode record at all, and absent has to mean
  # absent rather than a fifth rung of the ladder.
  describe "the posture axis" do
    def posture_run(name, posture)
      run(name, usage: usage(input: 10, output: 1), cost: "0.001", posture:)
    end

    def compare(*postures)
      described_class.new(postures.each_with_index.map { |posture, i| posture_run("r#{i}", posture) })
    end

    it "compares two runs recorded under the same posture" do
      expect { compare(:accept_edits, :accept_edits) }.not_to raise_error
    end

    it "refuses runs under different postures, naming both" do
      expect { compare(:manual, :auto) }
        .to raise_error(Lain::Error, /\bmanual\b.*\bauto\b/m)
    end

    it "compares runs whose journals hold no mode record -- a run from before modes existed" do
      expect { compare(nil, nil) }.not_to raise_error
    end

    # THE example for why the guard is `combination(2)` and not the degraded
    # guard's `each_cons(2)`. Agreement is not transitive here: an unrecorded
    # posture agrees with both its neighbours, so an adjacent-pairwise walk
    # waves `manual` and `auto` through on the strength of the absence sitting
    # between them -- and reverting the guard to `each_cons` fails nothing else
    # in this file.
    it "refuses postures that differ across an unrecorded run standing between them" do
      expect { compare(:manual, nil, :auto) }
        .to raise_error(Lain::Error, /\bmanual\b.*\bauto\b/m)
    end

    # Absence is not a claim, so it cannot contradict one. A guard that refused
    # here would be treating "not recorded" as a fifth posture, which is exactly
    # what every pre-modes fixture would then fail on.
    it "compares an unrecorded run against a recorded one -- absent is absent, not a fifth posture" do
      expect { compare(:manual, nil) }.not_to raise_error
      expect { compare(nil, :manual) }.not_to raise_error
    end

    it "refuses a posture name that is not on the ladder, naming the roster" do
      expect { posture_run("typo", :acept_edits) }
        .to raise_error(ArgumentError, /unknown posture.*accept_edits/m)
    end

    it "keeps a Run with a posture Ractor-shareable" do
      expect(posture_run("a", :manual)).to be_deeply_frozen
    end

    describe "the report" do
      it "states the posture when every run used the same one" do
        expect(compare(:accept_edits, :accept_edits).report).to include("posture: accept_edits")
      end

      it "names each run's posture when they were not all recorded alike" do
        report = compare(:manual, nil).report
        expect(report).to include("r0=manual").and include("r1=not recorded")
      end

      it "says a posture was not recorded rather than inventing one" do
        expect(described_class.new(runs).report).to include("posture: not recorded")
      end

      # Both facts on this line are comma lists of their own, so an undelimited
      # header reads "degraded: extended_output, thinking, posture: a=manual"
      # and a reader cannot see where the capability list ends.
      it "delimits the header's facts, so neither comma list runs into the other" do
        degraded = Lain::Capability::DegradedSet.new(%i[thinking extended_output])
        pair = [nil, nil].each_with_index.map do |_, i|
          run("r#{i}", usage: usage(input: 10, output: 1), cost: "0.001", degraded:)
        end
        expect(described_class.new(pair).report.lines.first.chomp)
          .to eq("Compare — 2 runs | degraded: extended_output, thinking | posture: not recorded")
      end
    end
  end
end
