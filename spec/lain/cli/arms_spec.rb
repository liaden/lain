# frozen_string_literal: true

RSpec.describe Lain::CLI::Arms do
  describe ".from" do
    it "parses the three flags into symbols" do
      arms = described_class.from({ confine: "reader", judge_facts: "facts", tripwire: "observe" })

      expect([arms.confine, arms.judge_facts, arms.tripwire]).to eq(%i[reader facts observe])
    end

    it "runs the safe arms when no flag was typed, and keeps judge facts off" do
      arms = described_class.from({})

      expect([arms.confine, arms.tripwire, arms.judge_facts]).to eq(%i[reader observe off])
    end

    it "turns each safe arm off when its flag says off" do
      expect(described_class.from({ confine: "off", tripwire: "off" })).to eq(described_class::OFF)
    end

    it "refuses a confine value outside the set, naming the allowed values" do
      expect { described_class.from({ confine: "sideways" }) }
        .to raise_error(described_class::Unknown, /sideways.*off, classes, reader/)
    end

    it "refuses an unknown judge_facts and an unknown tripwire" do
      expect { described_class.from({ judge_facts: "all" }) }.to raise_error(described_class::Unknown, /judge.facts/)
      expect { described_class.from({ tripwire: "kill" }) }.to raise_error(described_class::Unknown, /tripwire/)
    end
  end

  describe "#to_header" do
    it "is empty when every arm is off" do
      expect(described_class::OFF.to_header).to eq({})
    end

    it "records the 2 safe arms a plain launch runs" do
      expect(described_class.from({}).to_header).to eq("confine" => "reader", "tripwire" => "observe")
    end

    it "names only the arms that are on, as strings" do
      expect(described_class.from({ confine: "reader", tripwire: "off" }).to_header).to eq("confine" => "reader")
    end
  end
end
