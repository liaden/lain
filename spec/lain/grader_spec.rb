# frozen_string_literal: true

RSpec.describe Lain::Grader::Grade do
  it "carries no failure kind unless told one" do
    expect(described_class.new(score: 0.0, why: "missed").failure_kind).to be_nil
  end

  it "keeps a known failure kind" do
    expect(described_class.new(score: 0.0, why: "boom", failure_kind: :grader).failure_kind).to eq(:grader)
  end

  it "refuses a failure kind outside the attribution kinds" do
    expect { described_class.new(score: 0.0, why: "boom", failure_kind: :weather) }
      .to raise_error(ArgumentError, /weather/)
  end

  it "stays shareable with a failure kind" do
    expect(Ractor.shareable?(described_class.new(score: 0.0, why: "boom", failure_kind: :grader))).to be(true)
  end

  describe "from a Fixture" do
    def grade_of(&check) = Lain::Grader::Fixture.new("t") { |f| f.check("c", &check) }.grade(:subject)

    it "marks a raising predicate as a grader failure" do
      expect(grade_of { raise "bad predicate" }.failure_kind).to eq(:grader)
    end

    it "leaves a predicate that simply did not hold unattributed" do
      expect(grade_of { false }.failure_kind).to be_nil
    end
  end
end
