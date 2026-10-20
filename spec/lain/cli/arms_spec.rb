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
      expect(described_class.from({ confine: "off", tripwire: "off", round_budget: "off", round_dedup: "off" }))
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
      recorded = described_class.new(confine: :classes, judge_facts: :facts, tripwire: :off, round_budget: :static,
                                     round_dedup: :on)

      expect(described_class.from({}, recorded)).to eq(recorded)
      expect(described_class.from({ confine: "off" }, recorded))
        .to eq(described_class.new(confine: :off, judge_facts: :facts, tripwire: :off, round_budget: :static,
                                   round_dedup: :on))
    end
  end

  describe "the round_dedup arm" do
    it "is on by default, off by flag, and refuses a value outside its set" do
      expect(described_class.from({}).round_dedup).to eq(:on)
      expect(described_class.from({ round_dedup: "off" }).round_dedup).to eq(:off)
      expect { described_class.from({ round_dedup: "maybe" }) }.to raise_error(described_class::Unknown, /round.dedup/)
    end

    it "reads a header without the key as on under a budget, which always deduplicated, and off otherwise" do
      expect(described_class.from_header({ "arms" => { "round_budget" => "window" } }).round_dedup).to eq(:on)
      expect(described_class.from_header({ "arms" => { "round_budget" => "static" } }).round_dedup).to eq(:on)
      expect(described_class.from_header({ "arms" => { "confine" => "reader" } }).round_dedup).to eq(:off)
      expect(described_class.from_header({ "arms" => { "round_budget" => "window",
                                                       "round_dedup" => "off" } }).round_dedup)
        .to eq(:off)
    end

    it "makes a budget of off a dedup-only policy, and both off the unbounded one" do
      records = []
      blocks = [{ "content" => "x" }, { "content" => "x" }]
      calls = %w[a b].map { |id| Lain::Tool::RoundBudget::Call.new(id:, tool: Lain::Tools::ReadFile.new) }
      described_class.from({ round_budget: "off" }).round_budget_policy.for(head: "h") { raise "room" }
                     .call(blocks, calls) { |record| records << record }
      expect(records.first.deduplicated).to eq(["b"])
      expect(described_class.from({ round_budget: "off", round_dedup: "off" }).round_budget_policy)
        .to be(Lain::Tool::RoundBudget::NONE)
    end

    it "delivers a repeat whole under a budget when dedup is off" do
      records = []
      blocks = [{ "content" => "x" }, { "content" => "x" }]
      calls = %w[a b].map { |id| Lain::Tool::RoundBudget::Call.new(id:, tool: Lain::Tools::ReadFile.new) }
      room = Lain::Tool::Room.new(window: 32_768, usage: Lain::Usage.zero, ceiling: 16_384)
      delivered = described_class.from({ round_budget: "window", round_dedup: "off" }).round_budget_policy
                                 .for(head: "h") { room }.call(blocks, calls) { |record| records << record }

      expect(delivered).to eq(blocks)
      expect(records).to be_empty
    end

    it "names a dedup turned off as weaker than the default, and a static budget as different" do
      expect(described_class.from({ round_dedup: "off", round_budget: "static" }).differs_from_default)
        .to contain_exactly(:round_dedup, :round_budget)
      expect(described_class::DEFAULT.differs_from_default).to be_empty
    end
  end

  describe ".from_header" do
    it "reads the arms a session header recorded" do
      header = { "arms" => { "confine" => "reader", "tripwire" => "observe" } }

      expect(described_class.from_header(header))
        .to eq(described_class.new(confine: :reader, judge_facts: :off, tripwire: :observe, round_budget: :off,
                                   round_dedup: :off))
    end

    it "reads a recorded round budget back" do
      expect(described_class.from_header({ "arms" => { "round_budget" => "static" } }).round_budget).to eq(:static)
    end

    it "reads an arm the header left out as off, and a header with no arms as every arm off" do
      expect(described_class.from_header({ "arms" => { "confine" => "classes" } }))
        .to eq(described_class.new(confine: :classes, judge_facts: :off, tripwire: :off, round_budget: :off,
                                   round_dedup: :off))
      expect(described_class.from_header({ "model" => "qwen3:4b" })).to eq(described_class::OFF)
    end

    it "refuses a recorded value outside an arm's set, naming the session header" do
      expect { described_class.from_header({ "arms" => { "confine" => "sideways" } }) }
        .to raise_error(described_class::Unknown, /session header records confine "sideways"/)
    end
  end

  describe "#to_header" do
    it "writes only round_dedup when every arm is off, and nothing when none was set" do
      expect(described_class::OFF.to_header).to eq("round_dedup" => "off")
      expect(described_class::UNSET.to_header).to eq({})
    end

    it "records the 4 default-on arms a plain launch runs" do
      expect(described_class.from({}).to_header)
        .to eq("confine" => "reader", "tripwire" => "observe", "round_budget" => "window", "round_dedup" => "on")
    end

    it "names only the arms that are on, as strings" do
      expect(described_class.from({ confine: "reader", tripwire: "off", round_budget: "off",
                                    round_dedup: "off" }).to_header)
        .to eq("confine" => "reader", "round_dedup" => "off")
    end
  end
end
