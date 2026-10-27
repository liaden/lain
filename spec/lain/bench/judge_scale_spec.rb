# frozen_string_literal: true

require "tempfile"

# Compares how a judge's scale shape treats findings with known labels. No model is called:
# a refuter here replays a verdict decided by the spec.
RSpec.describe Lain::Bench::JudgeScale do
  fixture = File.expand_path("../../fixtures/grader/findings/labelled.jsonl", __dir__)
  let(:findings) { described_class.load(fixture) }
  let(:false_count) { findings.count { !_1.fetch("label") } }

  # A refuter that answers each finding with the score `pick` gives for it.
  def refuter_scoring(threshold)
    Class.new do
      define_method(:initialize) { |pick| @pick = pick }
      define_method(:refute) do |finding|
        score = @pick.call(finding)
        Lain::Grader::Grade.new(score:, why: "decided", pass: score >= threshold)
      end
    end
  end

  def label_of(finding) = findings.find { _1.fetch("finding") == finding }.fetch("label")

  def row(rows, scale) = rows.find { _1.scale == scale }

  describe "the fixture" do
    it "labels every row true or false and marks it synthetic" do
      expect(findings.size).to be_between(18, 24)
      expect(findings.map { _1.fetch("label") }.uniq).to contain_exactly(true, false)
      expect(findings.map { _1.fetch("synthetic") }.uniq).to eq([true])
      expect(findings.map { _1.fetch("finding") }.uniq.size).to eq(findings.size)
    end
  end

  describe ".load" do
    def loaded(text)
      Tempfile.create(["findings", ".jsonl"]) do |file|
        file.write(text)
        file.flush
        described_class.load(file.path)
      end
    end

    it "refuses a row whose label is neither true nor false, naming its line" do
      text = %({"finding":"a","label":true}\n{"finding":"b","label":"maybe"}\n)

      expect { loaded(text) }.to raise_error(Lain::Bench::CLI::Refusal, /line 2.*label/)
    end

    it "refuses a row with no label and one with no finding" do
      expect { loaded(%({"finding":"a"}\n)) }.to raise_error(Lain::Bench::CLI::Refusal, /line 1/)
      expect { loaded(%({"label":true}\n)) }.to raise_error(Lain::Bench::CLI::Refusal, /line 1.*finding/)
    end

    it "refuses a line that is not JSON, naming its line" do
      expect { loaded(%({"finding":"a","label":true}\nnot json\n)) }
        .to raise_error(Lain::Bench::CLI::Refusal, /line 2/)
    end

    it "skips blank lines but counts them" do
      text = %({"finding":"a","label":true}\n\n{"finding":"b","label":1}\n)

      expect { loaded(text) }.to raise_error(Lain::Bench::CLI::Refusal, /line 3/)
    end

    it "refuses a file with no rows" do
      expect { loaded("") }.to raise_error(Lain::Bench::CLI::Refusal, /no findings/)
    end
  end

  describe "#rows" do
    def unit_score(finding)
      return 0.8 if wrong.include?(finding)

      label_of(finding) ? 0.9 : 0.2
    end

    # unit scores true findings 0.9 and false ones 0.2, except 2 false findings it scores 0.8.
    let(:wrong) { findings.reject { _1.fetch("label") }.first(2).map { _1.fetch("finding") } }
    let(:unit) { refuter_scoring(0.5).new(->(finding) { unit_score(finding) }) }
    let(:everything) { refuter_scoring(1.0).new(->(_) { 1.0 }) }
    let(:subject_rows) do
      described_class.new(findings:, scales: %i[unit binary],
                          refuter_for: ->(scale) { scale == :unit ? unit : everything }).rows
    end

    it "gives one row per scale in the order asked" do
      expect(subject_rows.map(&:scale)).to eq(%i[unit binary])
      expect(subject_rows.map(&:n)).to eq([findings.size] * 2)
    end

    it "counts the false findings that survived and bounds them one-sided" do
      unit_row = row(subject_rows, :unit)

      expect(unit_row.wrong_survived).to eq(2)
      expect(unit_row.wrong_bound).to eq(Lain::Compare::Stats.clopper_pearson_upper(2, false_count))
      expect(unit_row.accuracy).to eq((findings.size - 2).fdiv(findings.size))
    end

    it "scores a judge that passes everything as wrong on every false finding" do
      binary = row(subject_rows, :binary)

      expect(binary.wrong_survived).to eq(false_count)
      expect(binary.accuracy).to eq((findings.size - false_count).fdiv(findings.size))
    end

    it "computes Brier from the unit score against the label" do
      scores = findings.map do |f|
        if wrong.include?(f["finding"])
          0.8
        else
          (f["label"] ? 0.9 : 0.2)
        end
      end
      outcomes = findings.map { _1.fetch("label") ? 1.0 : 0.0 }

      expect(row(subject_rows, :unit).brier).to eq(Lain::Compare::Stats.brier(scores, outcomes))
    end

    it "withholds Brier from a scale whose scores are not probabilities" do
      expect(row(subject_rows, :binary).brier).to be_nil
    end

    it "asks the refuter factory once per scale" do
      asked = []
      described_class.new(findings:, scales: %i[unit three],
                          refuter_for: ->(scale) { (asked << scale) && unit }).rows

      expect(asked).to eq(%i[unit three])
    end

    it "refuses a scale outside the known four before asking anything" do
      expect { described_class.new(findings:, scales: %i[unit likert], refuter_for: ->(_) { raise "asked" }) }
        .to raise_error(Lain::Bench::CLI::Refusal, /likert/)
    end

    it "counts a set with no false findings as unmeasured, not as zero wrong" do
      only_true = findings.select { _1.fetch("label") }
      table = described_class.new(findings: only_true, scales: %i[unit], refuter_for: ->(_) { unit })

      expect(table.report).to include("no false findings")
    end
  end

  describe "#report" do
    let(:unit) { refuter_scoring(0.5).new(->(finding) { label_of(finding) ? 0.9 : 0.2 }) }
    let(:all_pass) { refuter_scoring(1.0).new(->(_) { 1.0 }) }
    let(:report) do
      described_class.new(findings:, scales: %i[unit binary three deduction],
                          refuter_for: ->(scale) { scale == :unit ? unit : all_pass }).report
    end

    it "prints a line per scale with n, accuracy, wrong survivors and the bound named one-sided" do
      line = report.lines.find { _1.start_with?("unit") }

      expect(line).to include("n=20", "accuracy 100.0%", "wrong survived 0 of #{false_count}")
      bound = format("%.1f", Lain::Compare::Stats.clopper_pearson_upper(0, false_count) * 100)
      expect(line).to include("one-sided 95% upper bound #{bound}%")
    end

    it "prints Brier for unit and withholds it, with the reason, for the other three" do
      expect(report.lines.find { _1.start_with?("unit") }).to match(/Brier 0\.\d{4}/)
      %w[binary three deduction].each do |name|
        expect(report.lines.find { _1.start_with?(name) }).to include("Brier withheld: scores are not probabilities")
      end
    end

    it "names the label set size once" do
      expect(report).to include("#{findings.size} labelled findings", "#{false_count} false")
    end
  end
end
