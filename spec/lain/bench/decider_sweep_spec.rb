# frozen_string_literal: true

# T6/OR-4: the decider-locus sweep. For T4's prune-scoring decision point,
# ranks heuristic vs ollama vs haiku vs inline vs model_self_directed over a
# committed, zero-network fixture (spec/fixtures/bench/decider/cases.yml) --
# reusing {Lain::Compare} itself (T5's cache-write column is exactly why this
# sweep, unlike {Lain::Bench::Sweep}/{Lain::Bench::DisclosureSweep}, can).
RSpec.describe Lain::Bench::DeciderSweep do
  def fixture_path(name) = File.join(__dir__, "..", "..", "fixtures", "bench", "decider", "#{name}.yml")

  subject(:sweep) { described_class.new(fixture_path: fixture_path("cases")) }

  # {Lain::Compare#report}'s per-run appendix is the LAST table in the
  # Compare block, which itself sits before this sweep's own "== Wall clock"
  # section -- split on that marker so a row-parse can never mix the two
  # same-shaped (6-cell, arm-first-column) tables together.
  def compare_section(report) = report.split("== Wall clock").first

  def wall_clock_section(report) = "== Wall clock#{report.split("== Wall clock").last}"

  # [arm, n, total tokens, cache hit ratio, cost, grader score, cache write
  # tokens], parsed from the ACTUAL rendered bytes (Compare::Table's
  # two-space column rule) -- spec/lain/bench/disclosure_sweep_spec.rb's own
  # precedent, never a private accessor.
  def arm_rows(section)
    section.lines.map(&:chomp).filter_map do |line|
      cells = line.split(/\s{2,}/)
      cells if described_class::ARMS.include?(cells.first)
    end
  end

  describe "#report — the five-arm decider comparison" do
    let(:report) { sweep.report }
    let(:rows) { arm_rows(compare_section(report)) }
    let(:by_arm) { rows.to_h { |row| [row.first, row] } }

    it "scores every arm the fixture names, and only those five" do
      expect(rows.map(&:first)).to contain_exactly(*described_class::ARMS)
    end

    it "grades the heuristic arm below the content-reading arms -- it gets the " \
       "age-but-still-active-allergy case wrong (3 of 4 correct)" do
      expect(Float(by_arm.fetch("heuristic")[4])).to eq(0.75)
    end

    it "grades every content-reading arm perfect on this fixture" do
      %w[ollama haiku inline model_self_directed].each do |arm|
        expect(Float(by_arm.fetch(arm)[4])).to eq(1.0)
      end
    end

    it "ranks arms by grader score descending -- heuristic (the only imperfect " \
       "arm) sorts last" do
      expect(rows.last.first).to eq("heuristic")
    end

    it "makes the inline arm's cache-write cost VISIBLE, not averaged away: it and " \
       "model_self_directed carry a real cache-write total, the three out-of-band " \
       "arms carry exactly zero" do
      expect(Float(by_arm.fetch("inline")[5])).to be > 0
      expect(Float(by_arm.fetch("model_self_directed")[5])).to be > 0
      expect(Float(by_arm.fetch("heuristic")[5])).to eq(0.0)
      expect(Float(by_arm.fetch("ollama")[5])).to eq(0.0)
      expect(Float(by_arm.fetch("haiku")[5])).to eq(0.0)
    end

    it "prices the free local ollama arm at exactly $0, never UnknownModel" do
      expect(Float(by_arm.fetch("ollama")[3])).to eq(0.0)
    end

    it "names the case and arm counts in its header" do
      expect(report).to match(/4 cases/)
      expect(report).to match(/5 arms/)
    end
  end

  describe "#report — the wall-clock section" do
    let(:report) { sweep.report }
    let(:rows) { arm_rows(wall_clock_section(report)) }
    let(:by_arm) { rows.to_h { |row| [row.first, row] } }

    it "records wall-clock only for the arms with replayed live history (ollama, haiku)" do
      expect(Integer(by_arm.fetch("ollama")[1])).to eq(4)
      expect(Integer(by_arm.fetch("haiku")[1])).to eq(4)
    end

    it "marks the never-live-timed arms ABSENT rather than fabricating a wall-clock number" do
      %w[heuristic inline model_self_directed].each do |arm|
        row = by_arm.fetch(arm)
        expect(Integer(row[1])).to eq(0)
        expect(row[2..]).to all(match(/ABSENT/))
      end
    end

    it "reports a real, non-degenerate distribution for the live-replayed arms" do
      expect(Float(by_arm.fetch("ollama")[4])).to be < Float(by_arm.fetch("ollama")[5]) # min < max
    end
  end

  describe "isolation: each arm scores over its own Timeline" do
    it "gives every arm a Timeline on its own Store" do
      stores = sweep.timelines.values.map(&:store)
      expect(stores.uniq.size).to eq(described_class::ARMS.size)
    end

    it "seeds ONLY inline and model_self_directed with the fixture's base_conversation -- " \
       "the other three arms never touch it" do
      lengths = sweep.timelines.transform_values(&:length)
      # 4 cases * 2 turns (question, answer) each, plus 2 base_conversation
      # turns for the two tail-warming arms only.
      expect(lengths.fetch("heuristic")).to eq(8)
      expect(lengths.fetch("ollama")).to eq(8)
      expect(lengths.fetch("haiku")).to eq(8)
      expect(lengths.fetch("inline")).to eq(10)
      expect(lengths.fetch("model_self_directed")).to eq(10)
    end
  end

  describe "determinism" do
    it "renders byte-identical reports across two independent instances" do
      first = described_class.new(fixture_path: fixture_path("cases")).report
      second = described_class.new(fixture_path: fixture_path("cases")).report
      expect(first).to eq(second)
    end

    it "renders byte-identical reports when the same instance reports twice" do
      expect(sweep.report).to eq(sweep.report)
    end
  end

  describe "a missing fixture refuses namedly" do
    it "raises a Lain::Error naming the missing path, not Errno::ENOENT" do
      missing = fixture_path("does-not-exist")

      expect { described_class.new(fixture_path: missing).report }
        .to raise_error(described_class::MissingFixture, /#{Regexp.escape(missing)}/)
    end
  end

  describe "a malformed fixture case refuses namedly rather than being silently skipped" do
    it "raises MalformedCase naming the missing top-level field" do
      expect { described_class.new(fixture_path: fixture_path("malformed")).report }
        .to raise_error(described_class::MalformedCase, /gold_stale/)
    end

    it "raises MalformedCase when an arm block is missing its answer -- the same " \
       "named-and-located error a missing top-level field gets" do
      expect { described_class.new(fixture_path: fixture_path("missing_arm_answer")).report }
        .to raise_error(described_class::MalformedCase, /answer/)
    end
  end
end
