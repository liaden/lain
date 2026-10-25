# frozen_string_literal: true

RSpec.describe Lain::Compare::Attribution do
  it "names the 4 kinds" do
    expect(described_class::KINDS).to eq(%i[environment reasoning grader prompt])
  end

  describe ".tally" do
    it "counts each kind and the outcomes with none" do
      tally = described_class.tally(%i[reasoning environment reasoning grader prompt] + [nil])

      expect(tally).to eq(environment: 1, reasoning: 2, grader: 1, prompt: 1, unattributed: 1)
    end

    it "answers a zero for every kind over no outcomes" do
      expect(described_class.tally([])).to eq(environment: 0, reasoning: 0, grader: 0, prompt: 0, unattributed: 0)
    end
  end

  describe ".sections" do
    run = Struct.new(:grade, :timeline, :kind)
    grade = Struct.new(:failure_kind) do
      def pass? = false
    end

    it "judges a graded run by its grade even when the run answers kind" do
      attempts = { "a" => [[run.new(grade.new(:grader), nil, :environment)]] }

      table = described_class.sections(attempts, tasks: ["t"], labels: Lain::Bench::Labels::NONE).first

      expect(table).to match(/^a\s+0\s+0\s+1\s+0\s+0$/)
    end
  end
end
