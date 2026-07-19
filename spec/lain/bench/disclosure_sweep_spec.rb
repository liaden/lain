# frozen_string_literal: true

# T14: a Compare-style report comparing the two Toolset::Disclosure arms that
# exist today -- Upfront (T12) and Deferred (T13) -- on upfront-disclosure
# tokens and correct-call rate, over a committed, zero-network fixture of
# tool-selection tasks (spec/fixtures/bench/disclosure/*). The code-API arm
# (M6, exec boundary) does not exist yet and is explicitly out of scope; the
# report must say so rather than silently present two arms as the whole axis.
RSpec.describe Lain::Bench::DisclosureSweep do
  def fixture_path(name) = File.join(__dir__, "..", "..", "fixtures", "bench", "disclosure", "#{name}.yml")

  # The data rows of the two-arm table: [arm, n, tokens mean, tokens median,
  # tokens min, tokens max, correct-call rate]. Parsed from the ACTUAL
  # rendered bytes (Compare::Table's two-space column rule), never a private
  # accessor -- spec/lain/bench/sweep_spec.rb's own precedent.
  def arm_rows(report)
    report.lines.map(&:chomp).filter_map do |line|
      cells = line.split(/\s{2,}/)
      cells if %w[upfront deferred].include?(cells.first)
    end
  end

  subject(:sweep) { described_class.new(fixture_path: fixture_path("tasks")) }

  describe "#report — the two-arm disclosure comparison" do
    let(:report) { sweep.report }

    it "scores both arms that exist today, and only those two" do
      expect(arm_rows(report).map(&:first)).to contain_exactly("upfront", "deferred")
    end

    it "uses every task in the fixture for both arms -- nothing is capped or sampled" do
      expect(arm_rows(report).map { |row| Integer(row[1]) }).to eq([5, 5])
    end

    it "reports the deferred arm's upfront-disclosure tokens as strictly cheaper than upfront's" do
      tokens_mean = arm_rows(report).to_h { |row| [row.first, Float(row[2])] }
      expect(tokens_mean.fetch("deferred")).to be < tokens_mean.fetch("upfront")
    end

    it "reports tokens AS A DISTRIBUTION, not a single repeated point -- the fixture's tasks " \
       "carry varying tool counts and description lengths on purpose" do
      arm_rows(report).each do |row|
        tokens_min, tokens_max = row[4..5].map { |cell| Float(cell) }
        expect(tokens_min).to be < tokens_max
      end
    end

    it "reports the correct-call rate the fixture's recorded picks actually earn" do
      correct_rate = arm_rows(report).to_h { |row| [row.first, Float(row.last)] }
      expect(correct_rate.fetch("upfront")).to eq(1.0)
      expect(correct_rate.fetch("deferred")).to eq(0.6)
    end

    it "notes the code-API arm is deferred (M6), not silently omitted" do
      expect(report).to match(/code-API/).and match(/out of scope/i)
    end

    it "names the task count in its header" do
      expect(report).to match(/5 tasks/)
    end
  end

  describe "determinism" do
    it "renders byte-identical reports across two independent runs" do
      first = described_class.new(fixture_path: fixture_path("tasks")).report
      second = described_class.new(fixture_path: fixture_path("tasks")).report
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
        .to raise_error(Lain::Bench::DisclosureSweep::MissingFixture, /#{Regexp.escape(missing)}/)
    end
  end

  describe "a malformed fixture task refuses namedly rather than being silently skipped" do
    it "raises MalformedTask naming the missing top-level field" do
      expect { described_class.new(fixture_path: fixture_path("malformed")).report }
        .to raise_error(Lain::Bench::DisclosureSweep::MalformedTask, /gold_tool/)
    end

    it "raises MalformedTask when a task's `recorded` is missing a per-arm pick -- " \
       "never silently scores that arm off a swallowed KeyError" do
      expect { described_class.new(fixture_path: fixture_path("missing_recorded_arm")).report }
        .to raise_error(Lain::Bench::DisclosureSweep::MalformedTask, /deferred/)
    end

    it "raises MalformedTask when a nested tool entry is missing `description`, " \
       "the same named-and-located error a top-level field gets" do
      expect { described_class.new(fixture_path: fixture_path("malformed_tool")).report }
        .to raise_error(Lain::Bench::DisclosureSweep::MalformedTask, /description/)
    end
  end
end
