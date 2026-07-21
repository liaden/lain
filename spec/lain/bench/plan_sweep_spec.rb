# frozen_string_literal: true

require "tmpdir"

# PC-6: the shape x density sweep, the chunk's closing deliverable. One fixed
# multi-step plan runs under six arms -- shapes (Plan::LinearRewrite /
# Plan::ForkPerStep) crossed with seam densities (every / thinned / none) -- and
# each arm reports grader, tokens, and cache-write DISTRIBUTIONS over the
# scripted runs. The reactive `cache-aware-compaction` baseline (the `none`
# density) is a first-class arm, so plan-shaped compaction has to BEAT it. Two
# things must hold: the sweep ranks the shapes honestly (every column present,
# wall-clock ABSENT under replay, the baseline an arm not a footnote), and the
# whole thing is byte-identical across reruns.

RSpec.describe Lain::Bench::PlanSweep do
  # The committed fixtures: one authored plan (author-thinned seams) and the
  # scripted runs + gold. Explicit paths, no lib->spec coupling (the ArmSweep
  # discipline).
  def fixtures = { plan_path: "spec/fixtures/plans/plan.md", runs_path: "spec/fixtures/plans/runs.yml" }

  def sweep = described_class.new(**fixtures)

  def measurements_by_arm = sweep.measurements.group_by(&:arm)

  describe "the six arms" do
    it "crosses two shapes with three densities, reactive baseline included" do
      expect(sweep.arms.map(&:label)).to eq(
        ["linear / every", "linear / thinned", "linear / none",
         "fork / every", "fork / thinned", "fork / none"]
      )
    end

    it "measures every arm over every scripted run" do
      by_arm = measurements_by_arm
      expect(by_arm.keys.size).to eq(6)
      expect(by_arm.values.map(&:size).uniq).to eq([3])
      expect(by_arm.fetch("linear / every").map(&:run_id)).to eq(%w[alpha bravo charlie])
    end
  end

  describe "Scenario: the sweep ranks shapes honestly" do
    subject(:report) { sweep.report }

    it "reports grader, tokens, and cache-write distributions for every arm" do
      ["grader score", "context bytes", "cache-writes"].each { |metric| expect(report).to include(metric) }
      # One table row per arm under each metric -- every arm named, none dropped.
      sweep.arms.map(&:label).each { |arm| expect(report.scan(/#{Regexp.escape(arm)}/).size).to be >= 3 }
    end

    it "marks wall-clock ABSENT under replay rather than fabricating a number" do
      expect(report).to include("wall-clock (s)", "ABSENT (mock)")
      expect(report).to match(/wall-clock is ABSENT under offline mock replay/)
    end

    it "shows the reactive baseline as a first-class arm, not a footnote" do
      expect(report).to include("fork / none (baseline)", "linear / none (baseline)")
      # It has real distribution rows (an n column of 3), not a prose aside.
      baseline_rows = report.lines.select { |line| line.include?("none (baseline)") && line.match?(/\s3\s/) }
      expect(baseline_rows).not_to be_empty
    end

    it "derives cache-writes from Bench::Rewrites, not Usage (the escalation trigger)" do
      # Fork-per-step's mainline is append-only: zero rewrites, proven over the
      # continuation chain the same way P3's seam-policy spec proves it.
      ["fork / every", "fork / thinned"].each do |arm|
        writes = measurements_by_arm.fetch(arm).map(&:cache_writes)
        expect(writes).to all(eq(0))
      end
      # LinearRewrite rewrites once per seam, so the finer density writes more.
      linear_every = measurements_by_arm.fetch("linear / every").map(&:cache_writes)
      linear_thinned = measurements_by_arm.fetch("linear / thinned").map(&:cache_writes)
      expect(linear_every).to all(be > 0)
      expect(linear_every.max).to be > linear_thinned.max
    end

    it "runs the reactive baseline as a real cache-aware-compaction arm that actually compacts" do
      baseline = measurements_by_arm.fetch("fork / none")
      expect(baseline.map(&:cache_writes)).to all(be > 0)
      # And it genuinely reduces resent context versus never compacting: its
      # tokens sit below the finest-density linear rewrite arm on the same runs.
      linear_every = measurements_by_arm.fetch("linear / every").sort_by(&:run_id).map(&:tokens)
      baseline.sort_by(&:run_id).map(&:tokens).zip(linear_every).each do |reactive, linear|
        expect(reactive).to be < linear
      end
    end

    it "keeps grader score arm-invariant -- the work product depends on the run, not the shape" do
      per_arm_scores = measurements_by_arm.transform_values { |cells| cells.sort_by(&:run_id).map(&:score) }
      expect(per_arm_scores.values.uniq.size).to eq(1)
      # And the run with the wrong s3 is what makes the score distribution real.
      expect(per_arm_scores.fetch("linear / every")).to eq([1.0, 0.75, 1.0])
    end

    it "makes both `none` rows identical -- one reactive baseline under two nominal shapes" do
      linear_none = measurements_by_arm.fetch("linear / none").sort_by(&:run_id)
      fork_none = measurements_by_arm.fetch("fork / none").sort_by(&:run_id)
      expect(linear_none.map(&:tokens)).to eq(fork_none.map(&:tokens))
      expect(linear_none.map(&:cache_writes)).to eq(fork_none.map(&:cache_writes))
    end
  end

  describe "Scenario: byte-identical reruns" do
    it "renders two independent sweeps byte-for-byte identically" do
      expect(described_class.new(**fixtures).report).to eq(described_class.new(**fixtures).report)
    end

    it "memoizes so one instance reports identically twice" do
      instance = sweep
      expect(instance.report).to equal(instance.report)
    end
  end

  describe "the fixture plan drives the density axis by editing seams" do
    it "derives every / thinned / none from one authored plan without changing step content" do
      fixture = Lain::Bench::PlanSweep::Fixture.new(**fixtures)
      steps = ->(density) { fixture.document_for(density).chunks.map { |chunk| chunk.map(&:id) } }
      expect(steps.call(:thinned)).to eq([%w[s1], %w[s2 s3], %w[s4]])
      expect(steps.call(:every)).to eq([%w[s1], %w[s2], %w[s3], %w[s4]])
      expect(steps.call(:none)).to eq([%w[s1 s2 s3 s4]])
      # Same steps, same digest-bearing content -- only the seams moved.
      expect(fixture.document_for(:every).steps).to eq(fixture.document_for(:none).steps)
    end
  end

  describe "the CLI surface returns the report as a String" do
    it "answers plan_sweep_report without touching stdout" do
      report = Lain::Bench::CLI.new.plan_sweep_report(**fixtures)
      expect(report).to be_a(String).and(include("Plan-shaped compaction sweep"))
    end
  end

  describe "a missing fixture is a loud, path-bearing error" do
    it "raises MissingFixture naming the path, never a bare Errno" do
      expect { described_class.new(plan_path: "no/such/plan.md", runs_path: fixtures[:runs_path]).measurements }
        .to raise_error(Lain::Bench::PlanSweep::Fixture::MissingFixture, %r{no/such/plan\.md})
    end
  end

  describe "a structurally broken fixture fails loud, never a vacuous report" do
    around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

    it "raises when the plan parses no steps, naming the path" do
      plan = File.join(@dir, "empty.md")
      File.write(plan, "# Just prose, no plan\n\nNothing here parses as a step line.\n")
      expect { described_class.new(plan_path: plan, runs_path: fixtures[:runs_path]) }
        .to raise_error(Lain::Bench::PlanSweep::Fixture::MalformedFixture, /empty\.md/)
    end

    it "raises when a scripted run is missing a plan-required step, naming the run and the step" do
      runs = File.join(@dir, "runs_missing_s3.yml")
      File.write(runs, <<~YAML)
        gold:
          "lib/parser.rb": "def parse_flags"
        runs:
          - id: alpha
            steps:
              s1: { file: "lib/parser.rb", content: "def parse_flags(a)\\n  a\\nend" }
              s2: { file: "lib/handler.rb", content: "class Handler\\nend" }
              s4: { file: "README.md", content: "## Usage" }
      YAML
      expect { described_class.new(plan_path: fixtures[:plan_path], runs_path: runs) }
        .to raise_error(Lain::Bench::PlanSweep::Fixture::MalformedFixture, /alpha.*s3|s3.*alpha/m)
    end
  end
end
