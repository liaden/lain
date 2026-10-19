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

    it "turns each default-on arm off when its flag says off" do
      expect(described_class.from({ confine: "off", tripwire: "off", round_budget: "off" }))
        .to eq(described_class::OFF)
    end

    it "budgets a tool round by the window unless told otherwise" do
      expect(described_class.from({}).round_budget).to eq(:window)
      expect(described_class.from({ round_budget: "static" }).round_budget).to eq(:static)
    end

    it "refuses a round_budget value outside the set, naming the flag and the allowed values" do
      expect { described_class.from({ round_budget: "huge" }) }
        .to raise_error(described_class::Unknown, /--round-budget.*huge.*off, static, window/)
    end

    it "refuses a confine value outside the set, naming the allowed values" do
      expect { described_class.from({ confine: "sideways" }) }
        .to raise_error(described_class::Unknown, /sideways.*off, classes, reader/)
    end

    it "refuses an unknown judge_facts and an unknown tripwire" do
      expect { described_class.from({ judge_facts: "all" }) }.to raise_error(described_class::Unknown, /judge.facts/)
      expect { described_class.from({ tripwire: "kill" }) }.to raise_error(described_class::Unknown, /tripwire/)
    end

    it "takes an unset arm from the arms it is laid over, and a typed one wins" do
      recorded = described_class.new(confine: :classes, judge_facts: :facts, tripwire: :off, round_budget: :static)

      expect(described_class.from({}, recorded)).to eq(recorded)
      expect(described_class.from({ confine: "off" }, recorded))
        .to eq(described_class.new(confine: :off, judge_facts: :facts, tripwire: :off, round_budget: :static))
    end
  end

  describe ".from_header" do
    it "reads the arms a session header recorded" do
      header = { "arms" => { "confine" => "reader", "tripwire" => "observe" } }

      expect(described_class.from_header(header))
        .to eq(described_class.new(confine: :reader, judge_facts: :off, tripwire: :observe, round_budget: :off))
    end

    it "reads a recorded round budget back" do
      expect(described_class.from_header({ "arms" => { "round_budget" => "static" } }).round_budget).to eq(:static)
    end

    it "reads an arm the header left out as off, and a header with no arms as every arm off" do
      expect(described_class.from_header({ "arms" => { "confine" => "classes" } }))
        .to eq(described_class.new(confine: :classes, judge_facts: :off, tripwire: :off, round_budget: :off))
      expect(described_class.from_header({ "model" => "qwen3:4b" })).to eq(described_class::OFF)
    end

    it "refuses a recorded value outside an arm's set, naming the session header" do
      expect { described_class.from_header({ "arms" => { "confine" => "sideways" } }) }
        .to raise_error(described_class::Unknown, /session header records confine "sideways"/)
    end
  end

  describe "#to_header" do
    it "is empty when every arm is off, or none was set" do
      expect(described_class::OFF.to_header).to eq({})
      expect(described_class::UNSET.to_header).to eq({})
    end

    it "records the 3 default-on arms a plain launch runs" do
      expect(described_class.from({}).to_header)
        .to eq("confine" => "reader", "tripwire" => "observe", "round_budget" => "window")
    end

    it "names only the arms that are on, as strings" do
      expect(described_class.from({ confine: "reader", tripwire: "off", round_budget: "off" }).to_header)
        .to eq("confine" => "reader")
    end
  end
end
