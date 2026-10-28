# frozen_string_literal: true

RSpec.describe Lain::Grader::Ndcg do
  describe "#grade" do
    let(:ndcg) { described_class.new(relevance: { "a" => 3, "b" => 1 }) }

    it "scores 1.0 when the higher-graded hit is ranked first" do
      expect(ndcg.grade(%w[a b], depth: 10).score).to eq(1.0)
    end

    it "scores below 1.0 when a lower-graded hit outranks a higher-graded one" do
      expect(ndcg.grade(%w[b a], depth: 10).score).to be < 1.0
    end

    it "scores 0.0 when no graded id is retrieved" do
      expect(ndcg.grade(%w[x y], depth: 10).score).to eq(0.0)
    end

    it "matches the hand-computed value, which pins the exponential gain" do
      graded = described_class.new(relevance: { "a" => 3, "b" => 1, "c" => 2 })

      expect(graded.grade(%w[b a x], depth: 3).score).to be_within(0.00005).of(0.5767)
    end

    it "never scores above 1.0 when a hit id repeats" do
      expect(described_class.new(relevance: { "a" => 3 }).grade(%w[a a a], depth: 10).score).to eq(1.0)
    end

    it "ignores a graded hit past k" do
      expect(ndcg.grade(%w[x a], depth: 1).score).to eq(0.0)
    end

    it "accepts anything duck-typed with #id" do
      hit = Struct.new(:id).new("a")

      expect(ndcg.grade([hit, "b"], depth: 10).score).to eq(1.0)
    end

    it "explains the grade" do
      expect(ndcg.grade(%w[b a], depth: 10).why).to include("ndcg@10")
    end
  end

  describe "construction" do
    it "refuses a relevance map with no positive grade" do
      expect { described_class.new(relevance: { "a" => 0 }) }.to raise_error(ArgumentError, /relevance/)
    end

    it "refuses a grade outside 0..3" do
      expect { described_class.new(relevance: { "a" => 4 }) }.to raise_error(ArgumentError, /0..3/)
    end
  end
end
