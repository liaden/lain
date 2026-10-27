# frozen_string_literal: true

RSpec.describe Lain::Grader::Rubric::Scale do
  def unparseable = Lain::Grader::Rubric::Unparseable

  it "names the four scales, unit first" do
    expect(described_class::NAMES).to eq(%i[unit binary three deduction])
  end

  it "refuses an unknown scale by name" do
    expect { described_class.fetch(:likert) }.to raise_error(ArgumentError, /likert.*unit, binary, three, deduction/)
  end

  it "fetches the same scale for a string as for a symbol" do
    expect(described_class.fetch("three")).to be(described_class.fetch(:three))
  end

  describe "unit" do
    subject(:scale) { described_class.fetch(:unit) }

    it "keeps today's instruction, threshold and score" do
      expect(scale.instruction).to equal(Lain::Grader::Rubric::INSTRUCTION)
      expect(scale.survives_at).to eq(0.5)
      expect(scale.score({ "score" => 0.7 })).to eq(0.7)
      expect(scale.score({})).to eq(0)
      expect(scale).to be_probability
    end
  end

  describe "binary" do
    subject(:scale) { described_class.fetch(:binary) }

    it "scores holds 1.0 and fails 0.0" do
      expect(scale.score({ "verdict" => "holds" })).to eq(1.0)
      expect(scale.score({ "verdict" => "fails" })).to eq(0.0)
    end

    it "raises on a number, an unknown word, or no verdict" do
      expect { scale.score({ "verdict" => 0.9 }) }.to raise_error(unparseable, /verdict/)
      expect { scale.score({ "score" => 0.9 }) }.to raise_error(unparseable)
      expect { scale.score({ "verdict" => "unsure" }) }.to raise_error(unparseable)
    end

    it "is not a probability and survives only at 1.0" do
      expect(scale).not_to be_probability
      expect(scale.survives_at).to eq(1.0)
    end
  end

  describe "three" do
    subject(:scale) { described_class.fetch(:three) }

    it "maps holds, unsure and fails to 1.0, 0.5 and 0.0" do
      expect(%w[holds unsure fails].map { scale.score({ "verdict" => _1 }) }).to eq([1.0, 0.5, 0.0])
    end

    it "needs holds to survive" do
      expect(scale.survives_at).to eq(1.0)
      expect(scale).not_to be_probability
    end

    it "raises on a word outside the three" do
      expect { scale.score({ "verdict" => "maybe" }) }.to raise_error(unparseable, /maybe/)
    end
  end

  describe "deduction" do
    subject(:scale) { described_class.fetch(:deduction) }

    it "takes 0.25 off per named defect and floors at 0" do
      expect(scale.score({ "defects" => [] })).to eq(1.0)
      expect(scale.score({ "defects" => %w[a b] })).to eq(0.5)
      expect(scale.score({ "defects" => %w[a b c d e f] })).to eq(0.0)
    end

    it "names every defect in the why" do
      why = scale.why({ "defects" => ["no evidence", "wrong file"], "why" => "thin" })

      expect(why).to include("no evidence", "wrong file", "thin")
    end

    it "raises when defects is not a list of strings" do
      expect { scale.score({ "defects" => 2 }) }.to raise_error(unparseable, /defects/)
      expect { scale.score({ "defects" => [1] }) }.to raise_error(unparseable, /defects/)
      expect { scale.score({}) }.to raise_error(unparseable, /defects/)
    end

    it "raises on a blank or non-string defect" do
      expect { scale.score({ "defects" => ["ok", " "] }) }.to raise_error(unparseable, /defects/)
      expect { scale.score({ "defects" => [""] }) }.to raise_error(unparseable, /defects/)
      expect { scale.score({ "defects" => [nil] }) }.to raise_error(unparseable, /defects/)
    end

    it "raises on a duplicated defect, which would be one defect charged twice" do
      expect { scale.score({ "defects" => %w[same same] }) }.to raise_error(unparseable, /duplicate/)
    end

    it "scores an empty defect list 1.0 and explains it when the judge gave no why" do
      expect(scale.score({ "defects" => [] })).to eq(1.0)
      expect(scale.why({ "defects" => [], "why" => "" })).to eq("no defects named")
      expect(scale.why({ "defects" => [] })).to eq("no defects named")
      expect(scale.why({ "defects" => [], "why" => "clean" })).to eq("clean")
    end

    it "ignores keys it does not know" do
      expect(scale.score({ "defects" => ["one"], "extra" => 1 })).to eq(0.75)
    end

    it "survives with at most one defect" do
      expect(scale.survives_at).to eq(0.75)
      expect(scale.score({ "defects" => ["one"] })).to be >= scale.survives_at
      expect(scale.score({ "defects" => %w[one two] })).to be < scale.survives_at
    end
  end

  it "gives each scale its own instruction, each asking for the shape it parses" do
    texts = described_class::NAMES.map { described_class.fetch(_1).instruction }

    expect(texts.uniq.size).to eq(4)
    expect(texts[1..]).to all(include("verdict").or(include("defects")))
  end
end
