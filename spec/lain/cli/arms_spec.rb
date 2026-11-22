# frozen_string_literal: true

RSpec.describe Lain::CLI::Arms do
  describe ".from" do
    it "parses the three flags into symbols" do
      arms = described_class.from({ confine: "reader", judge_facts: "facts", tripwire: "observe" })

      expect([arms.confine, arms.judge_facts, arms.tripwire]).to eq(%i[reader facts observe])
    end

    it "runs the safe arms when no flag was typed, and keeps judge facts off" do
      arms = described_class.from({})

      expect([arms.confine, arms.tripwire, arms.judge_facts]).to eq(%i[workspace observe off])
    end

    it "takes reader and workspace as the arms that build a sandbox, workspace the stronger" do
      expect(described_class.from({ confine: "workspace" }).confine).to eq(:workspace)
      expect(described_class::SANDBOXED).to eq(%i[reader workspace])
      expect(described_class::CONFINE.last).to eq(:workspace)
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
        .to raise_error(described_class::Unknown, /sideways.*off, classes, reader, workspace/)
    end

    it "takes stop as the tripwire arm stronger than observe" do
      expect(described_class.from({ tripwire: "stop" }).tripwire).to eq(:stop)
      expect(described_class::TRIPWIRE).to eq(%i[off observe stop])
    end

    it "refuses an unknown judge_facts and an unknown tripwire" do
      expect { described_class.from({ judge_facts: "all" }) }.to raise_error(described_class::Unknown, /judge.facts/)
      expect { described_class.from({ tripwire: "kill" }) }.to raise_error(described_class::Unknown, /tripwire/)
    end

    it "parses the judge-denial arm, off unless typed, and refuses a value outside its set" do
      expect(described_class::JUDGE_DENIALS).to eq(%i[off escalate_only breaker])
      expect(described_class.from({}).judge_denials).to eq(:off)
      expect(described_class.from({ judge_denials: "breaker" }).judge_denials).to eq(:breaker)
      expect { described_class.from({ judge_denials: "always" }) }
        .to raise_error(described_class::Unknown, /--judge-denials.*off, escalate_only, breaker/)
    end

    it "takes an unset arm from the arms it is laid over, and a typed one wins" do
      recorded = described_class.new(confine: :classes, judge_facts: :facts, tripwire: :off, round_budget: :static,
                                     round_dedup: :on, judge_denials: :breaker, judge_opaque: :off)

      expect(described_class.from({}, recorded)).to eq(recorded)
      expect(described_class.from({ confine: "off" }, recorded))
        .to eq(described_class.new(confine: :off, judge_facts: :facts, tripwire: :off, round_budget: :static,
                                   round_dedup: :on, judge_denials: :breaker, judge_opaque: :off))
    end
  end

  describe "the round_dedup arm" do
    it "is on by default, off by flag, and refuses a value outside its set" do
      expect(described_class.from({}).round_dedup).to eq(:on)
      expect(described_class.from({ round_dedup: "off" }).round_dedup).to eq(:off)
      expect { described_class.from({ round_dedup: "maybe" }) }.to raise_error(described_class::Unknown, /round.dedup/)
    end

    it "reads a header without the key as off, whatever the budget" do
      expect(described_class.from_header({ "arms" => { "round_budget" => "window" } }).round_dedup).to eq(:off)
      expect(described_class.from_header({ "arms" => { "round_budget" => "window",
                                                       "round_dedup" => "on" } }).round_dedup)
        .to eq(:on)
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

    it "names a reader confine as weaker than the workspace default" do
      expect(described_class.from({ confine: "reader" }).differs_from_default).to eq([:confine])
    end
  end

  describe "the judge_opaque arm" do
    # Scenario: the arm ships off
    it "is off by default and on only when typed, and refuses a value outside its set" do
      expect(described_class::JUDGE_OPAQUE).to eq(%i[off on])
      expect([described_class::DEFAULT.judge_opaque, described_class.from({}).judge_opaque]).to eq(%i[off off])
      expect(described_class.from({ judge_opaque: "on" }).judge_opaque).to eq(:on)
      expect { described_class.from({ judge_opaque: "always" }) }
        .to raise_error(described_class::Unknown, /--judge-opaque.*off, on/)
    end

    it "routes opaque calls only when on, under the workspace sandbox" do
      expect(described_class::DEFAULT.judge_opaque?).to be(false)
      expect(described_class::DEFAULT.with(judge_opaque: :on).judge_opaque?).to be(true)
      expect(described_class::DEFAULT.with(judge_opaque: :on, confine: :reader).judge_opaque?).to be(false)
      expect(described_class::UNSET.judge_opaque?).to be(false)
    end

    it "leaves a plain launch's header as it was, and reads a header without it as off" do
      expect(described_class.from({}).to_header.keys).not_to include("judge_opaque")
      expect(described_class.from({ judge_opaque: "on" }).to_header).to include("judge_opaque" => "on")
      expect(described_class.from_header({ "arms" => { "confine" => "workspace" } }).judge_opaque).to eq(:off)
    end

    it "is named by every caller that builds the arms by hand" do
      expect do
        described_class.new(confine: :reader, judge_facts: :off, tripwire: :off, round_budget: :off,
                            round_dedup: :off, judge_denials: :off)
      end.to raise_error(ArgumentError, /judge_opaque/)
    end
  end

  describe ".from_header" do
    it "reads the arms a session header recorded" do
      header = { "arms" => { "confine" => "reader", "tripwire" => "observe" } }

      expect(described_class.from_header(header))
        .to eq(described_class.new(confine: :reader, judge_facts: :off, tripwire: :observe, round_budget: :off,
                                   round_dedup: :off, judge_denials: :off, judge_opaque: :off))
    end

    it "reads a recorded round budget back" do
      expect(described_class.from_header({ "arms" => { "round_budget" => "static" } }).round_budget).to eq(:static)
    end

    it "reads an arm the header left out as off, and a header with no arms as every arm off" do
      expect(described_class.from_header({ "arms" => { "confine" => "classes" } }))
        .to eq(described_class.new(confine: :classes, judge_facts: :off, tripwire: :off, round_budget: :off,
                                   round_dedup: :off, judge_denials: :off, judge_opaque: :off))
      expect(described_class.from_header({ "model" => "qwen3:4b" })).to eq(described_class::OFF)
    end

    it "refuses a recorded value outside an arm's set, naming the session header" do
      expect { described_class.from_header({ "arms" => { "confine" => "sideways" } }) }
        .to raise_error(described_class::Unknown, /session header records confine "sideways"/)
    end
  end

  describe "predicates" do
    it "answer the questions callers ask of the launch defaults" do
      arms = described_class::DEFAULT

      expect([arms.workspace?, arms.sandboxed?, arms.classes?]).to eq([true, true, true])
      expect([arms.tripwire_stops?, arms.tripwire_off?, arms.judge_facts?, arms.judge_requests?])
        .to eq([false, false, false, false])
    end

    it "read an unset arm as off" do
      arms = described_class::UNSET

      expect([arms.workspace?, arms.sandboxed?, arms.classes?, arms.tripwire_stops?, arms.judge_facts?,
              arms.judge_requests?]).to all(be(false))
      expect(arms.tripwire_off?).to be(true)
    end

    it "tell the stronger values from the weaker ones" do
      reader = described_class::DEFAULT.with(confine: :reader, tripwire: :stop, judge_facts: :request)

      expect([reader.workspace?, reader.sandboxed?, reader.tripwire_stops?, reader.judge_facts?,
              reader.judge_requests?]).to eq([false, true, true, true, true])
      expect(described_class::DEFAULT.with(confine: :classes)).to have_attributes(classes?: true, sandboxed?: false)
    end
  end

  describe "OFF and UNSET" do
    it "set every arm named in SETS to off and to nil" do
      expect(described_class::OFF.to_h.values).to all(eq(:off))
      expect(described_class::UNSET.to_h.values).to all(be_nil)
      expect(described_class::OFF.to_h.keys).to eq(described_class::SETS.keys)
    end
  end

  describe "#to_header" do
    it "writes only round_dedup when every arm is off, and nothing when none was set" do
      expect(described_class::OFF.to_header).to eq("round_dedup" => "off")
      expect(described_class::UNSET.to_header).to eq({})
    end

    it "records the 4 default-on arms a plain launch runs" do
      expect(described_class.from({}).to_header)
        .to eq("confine" => "workspace", "tripwire" => "observe", "round_budget" => "window", "round_dedup" => "on")
    end

    it "names only the arms that are on, as strings" do
      expect(described_class.from({ confine: "reader", tripwire: "off", round_budget: "off",
                                    round_dedup: "off" }).to_header)
        .to eq("confine" => "reader", "round_dedup" => "off")
    end
  end
end
