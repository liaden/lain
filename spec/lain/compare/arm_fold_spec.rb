# frozen_string_literal: true

require "bigdecimal"

# Compare::ArmFold is the TRANSPOSED fold: rows are arms, cells are one arm's
# distribution over its own samples. Compare's own fold puts metrics on the rows
# and folds ACROSS runs, which is why the arms-side-by-side bench reports could
# never delegate to it -- but the cell order under the columns, the label
# callable, and the "mark absent, never fabricate" row were still written out
# once per sweep. This spec pins the part that must not drift: which stat lands
# under which header.
RSpec.describe Lain::Compare::ArmFold do
  # Distinct mean, median, min and max: a fold that swaps two stat cells still
  # renders four numbers in four columns, so only distinct values expose it.
  # [1, 2, 6] -> mean 3.0, median 2, min 1, max 6.
  def samples = { "a" => [1, 2, 6], "b" => [10, 20, 60] }

  def metrics = { "score" => { of: :score, fmt: ->(value) { format("%.3f", value) } } }

  def fold(**kwargs) = described_class.new(**kwargs)

  def sections(fold = self.fold, metrics: self.metrics, arms: %w[a b], &samples)
    fold.sections(metrics, arms:, &samples)
  end

  # A section is "title\nheader\n-----\nrow…"; cells are Compare::Table's
  # two-space-separated columns, read out of the ACTUAL rendered bytes.
  def cells(section, arm)
    section.lines.map(&:chomp).map { |line| line.split(/\s{2,}/) }.find { |row| row.first == arm }
  end

  describe "the column contract" do
    it "declares arm, n, mean, median, min and max, in that order" do
      expect(described_class::HEADERS).to eq(%w[arm n mean median min max])
    end

    it "puts each stat under its declared header" do
      section = sections { |arm, _of| samples.fetch(arm) }.first
      # mean 3.0, median 2, min 1, max 6 -- four different numbers, so a
      # transposed pair would fail here rather than render plausibly.
      expect(cells(section, "a")).to eq(%w[a 3 3.000 2.000 1.000 6.000])
    end

    it "counts the samples, not the arms" do
      section = sections { |arm, _of| samples.fetch(arm) }.first
      expect(cells(section, "b")).to eq(%w[b 3 30.000 20.000 10.000 60.000])
    end
  end

  describe "#sections" do
    def two_metrics
      { "first" => { of: :one, fmt: ->(value) { format("%.1f", value) } },
        "second" => { of: :two, fmt: ->(value) { format("%.2f", value) } } }
    end

    it "renders one titled table per metric, in declaration order" do
      rendered = sections(metrics: two_metrics) { |arm, _of| samples.fetch(arm) }
      expect(rendered.map { |section| section.lines.first.chomp }).to eq(%w[first second])
    end

    it "asks the block for each (arm, metric) pair" do
      asked = []
      sections(metrics: two_metrics) do |arm, of|
        asked << [arm, of]
        [1, 2]
      end
      expect(asked).to eq([["a", :one], ["b", :one], ["a", :two], ["b", :two]])
    end

    it "formats each metric with its own formatter" do
      rendered = sections(metrics: two_metrics) { |arm, _of| samples.fetch(arm) }
      expect(cells(rendered.first, "a")).to eq(%w[a 3 3.0 2.0 1.0 6.0])
      expect(cells(rendered.last, "a")).to eq(%w[a 3 3.00 2.00 1.00 6.00])
    end

    it "keeps the arm rows in the order given" do
      section = sections(arms: %w[b a]) { |arm, _of| samples.fetch(arm) }.first
      rows = section.lines.drop(3).map { |line| line.split(/\s{2,}/).first }
      expect(rows).to eq(%w[b a])
    end

    it "labels a row through the label callable, so a control mark reaches every table" do
      section = sections(fold(label: ->(arm) { arm == "a" ? "a (control)" : arm })) { |arm, _of| samples.fetch(arm) }
                .first
      expect(section.lines.drop(3).first).to start_with("a (control)")
    end
  end

  describe "#absent_section — mark absent, never fabricate" do
    it "renders the marker in all four stat columns while keeping n real" do
      section = fold.absent_section("wall-clock (s)", arms: %w[a b], count: 3, marker: "ABSENT (mock)")
      expect(section.lines.first.chomp).to eq("wall-clock (s)")
      expect(cells(section, "a")).to eq(["a", "3", "ABSENT (mock)", "ABSENT (mock)", "ABSENT (mock)",
                                         "ABSENT (mock)"])
    end

    it "labels absent rows the same way a measured row is labelled" do
      section = fold(label: ->(arm) { "#{arm} (control)" })
                .absent_section("wall-clock (s)", arms: %w[a b], count: 0, marker: "ABSENT")
      expect(section.lines.drop(3).map { |line| line.split(/\s{2,}/).first }).to eq(["a (control)", "b (control)"])
    end
  end

  describe "#row — for the reports that append a column of their own" do
    it "returns the six cells, so a caller can extend them" do
      row = fold.row("a", Lain::Compare::Distribution.new([1, 2, 6]), fmt: ->(value) { format("%.3f", value) })
      expect(row).to eq(%w[a 3 3.000 2.000 1.000 6.000])
    end

    it "marks one arm absent without marking the section absent" do
      expect(fold.absent_row("a", count: 0, marker: "ABSENT (dry)"))
        .to eq(["a", "0", "ABSENT (dry)", "ABSENT (dry)", "ABSENT (dry)", "ABSENT (dry)"])
    end
  end

  # The reason a stats gem was rejected: a bench cost is BigDecimal and must
  # stay one all the way to the formatter, and an Integer min/max must not
  # arrive as a Float. The fold hands values straight to Distribution and the
  # formatter; it converts nothing.
  describe "numeric types survive the fold" do
    def typing = { "t" => { of: :t, fmt: ->(value) { value.class.name } } }

    it "hands BigDecimal cost figures to the formatter as BigDecimal" do
      section = sections(metrics: typing, arms: ["a"]) { |_arm, _of| [BigDecimal("0.001"), BigDecimal("0.002")] }
                .first
      expect(cells(section, "a")).to eq(%w[a 2 BigDecimal BigDecimal BigDecimal BigDecimal])
    end

    it "leaves an Integer metric's median, min and max as Integers" do
      section = sections(metrics: typing, arms: ["a"]) { |_arm, _of| [1, 2, 6] }.first
      # The mean of an Integer metric is a Float by design (Integer#/ floors --
      # see Distribution#divide); the other three stay Integers.
      expect(cells(section, "a")).to eq(%w[a 3 Float Integer Integer Integer])
    end
  end
end
