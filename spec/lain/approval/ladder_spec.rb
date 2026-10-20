# frozen_string_literal: true

require "stringio"

# Rungs kept out of the RSpec block (Lint/ConstantDefinitionInBlock). Each
# answers `#call(input)` and names itself, which is all a ladder asks of one.
module LadderSpecSupport
  Decision = Data.define(:verdict, :rung, :reason, :authority) do
    def initialize(verdict:, rung:, reason:, authority:) = super(verdict:, rung:, reason: -reason, authority:)
    def allow? = verdict == :allow
    def deny? = verdict == :deny
  end

  Silent = Data.define(:name) do
    def call(_input) = Lain::Approval::Ladder::ABSTAIN
  end

  Allower = Data.define(:name) do
    def call(_input) = Decision.new(verdict: :allow, rung: name, reason: "#{name} allows", authority: :automatic)
  end

  Human = Data.define(:name) do
    def call(_input) = Decision.new(verdict: :allow, rung: name, reason: "#{name} said yes", authority: :human)
  end

  Denier = Data.define(:name) do
    def call(_input) = Decision.new(verdict: :deny, rung: name, reason: "#{name} refuses", authority: :automatic)
  end

  class Boom < StandardError; end

  Raiser = Data.define(:name) do
    def call(_input) = raise(Boom, "#{name} is broken")
  end

  # An abstention with something to say, counting how often it was asked to.
  class Explaining
    attr_reader :name, :asked

    def initialize(name, reason = "#{name} has a doubt", &explain)
      @name = name
      @explain = explain || -> { reason }
      @asked = 0
    end

    def call(_input)
      Lain::Approval::Ladder.abstain do
        @asked += 1
        @explain.call
      end
    end
  end

  # Not a StandardError, so no rescue in the ladder can swallow it.
  class Consulted < Exception; end # rubocop:disable Lint/InheritException

  Tripwire = Data.define(:name) do
    def call(_input) = raise(Consulted, "a rung past the deciding one was consulted")
  end

  POOL = [Silent.new("s1"), Allower.new("a1"), Allower.new("a2"), Denier.new("d1"), Denier.new("d2"),
          Raiser.new("r1"), Raiser.new("r2")].freeze

  class Raising < Lain::Approval::Rule
    def decide(_call) = raise(Boom, "the rule itself is broken")
  end

  class Allowing < Lain::Approval::Rule
    def decide(call) = allow(call, because: "spec allows everything")
  end
end

RSpec.describe Lain::Approval::Ladder do
  let(:support) { LadderSpecSupport }

  def ladder(*rungs) = described_class[*rungs]

  def poisoned(built, exempt: nil) = described_class::Poisoning.new(built, exempt:).call(:input)

  # What a caller can see of an outcome: rung names, never object identity.
  def observed(outcome)
    [outcome.decision&.verdict, outcome.by, outcome.faults.map(&:rung)]
  end

  describe "bracketing under edge poisoning" do
    # Scenario: bracketing cannot turn an escalation into a final deny
    it "answers one suppressed allow, flat, nested left and nested right" do
      raiser = support::Raiser.new("raiser")
      allower = support::Allower.new("allower")
      denier = support::Denier.new("denier")

      answers = [ladder(raiser, allower, denier), ladder(ladder(raiser, allower), denier),
                 ladder(raiser, ladder(allower, denier))].map { observed(poisoned(_1)) }

      expect(answers.uniq).to eq([[nil, "raiser", ["raiser"]]])
      expect(poisoned(ladder(raiser, allower, denier))).to be_suppressed
    end
  end

  describe "nesting" do
    generator = -> { described_class[*Array.new(rand(0..3)) { LadderSpecSupport::POOL.sample }] }

    # Scenario: nesting is a monoid
    include_examples "a monoid",
                     operation: ->(a, b) { a + b },
                     identity: described_class[],
                     generator:,
                     equal: ->(a, b) { observed(poisoned(a)) == observed(poisoned(b)) }

    # Scenario: a fault inside a nested ladder is reported once at the edge
    it "lists an inner fault exactly once at the outer edge" do
      outcome = poisoned(ladder(ladder(support::Raiser.new("inner")), support::Denier.new("outer")))

      expect(outcome.faults.map(&:rung)).to eq(["inner"])
      expect(outcome.faults.sole).to have_attributes(error: "LadderSpecSupport::Boom", message: "inner is broken")
    end

    it "unwraps a nested decision, naming the leaf rung that made it" do
      expect(ladder(support::Silent.new("s"), ladder(support::Denier.new("leaf"))).call(:input).by).to eq("leaf")
    end
  end

  describe "first decisive" do
    it "never consults a rung past the deciding one" do
      expect { ladder(support::Denier.new("d"), support::Tripwire.new("t")).call(:input) }.not_to raise_error
    end

    it "does reach a rung past an abstaining one" do
      expect { ladder(support::Silent.new("s"), support::Tripwire.new("t")).call(:input) }
        .to raise_error(support::Consulted)
    end

    it "decides nothing when every rung abstained, or when it holds none" do
      expect(ladder(support::Silent.new("s")).call(:input)).not_to be_decided
      expect(ladder.call(:input)).not_to be_decided
    end

    it "faults a rung answering something that is not a decision, naming why" do
      [true, false, :allow].each do |answer|
        outcome = ladder(->(_input) { answer }, support::Denier.new("d")).call(:input)

        expect([outcome.by, outcome.faults.sole.error]).to eq(["d", "Lain::Approval::Ladder::NotADecision"])
      end
    end

    it "reads a nil answer as an abstention" do
      expect(ladder(->(_input) {}, support::Allower.new("a")).call(:input).by).to eq("a")
    end
  end

  describe "poisoning" do
    it "keeps a raw outcome's allow, faults and all, until the edge projects it" do
      raw = ladder(support::Raiser.new("r"), support::Allower.new("a")).call(:input)

      expect([raw.allow?, raw.faulted?]).to eq([true, true])
    end

    it "lets a deny past a fault decide, still attributed and still faulted" do
      outcome = poisoned(ladder(support::Raiser.new("r"), support::Denier.new("d")))

      expect([outcome.deny?, outcome.by, outcome.faulted?]).to eq([true, "d", true])
    end

    it "tells a lone fault apart from a plain abstention" do
      expect([poisoned(ladder(support::Raiser.new("r"))).faulted?, poisoned(ladder(support::Silent.new("s"))).faulted?])
        .to eq([true, false])
    end

    it "leaves a clean allow standing" do
      expect(poisoned(ladder(support::Allower.new("a")))).to be_allow
    end

    # Scenario: a human's allow survives a fault
    it "lets an exempt authority's allow stand over a fault, with the fault recorded" do
      outcome = poisoned(ladder(support::Raiser.new("r"), support::Human.new("surfaces")), exempt: :human)

      expect([outcome.allow?, outcome.by, outcome.faults.map(&:rung)]).to eq([true, "surfaces", ["r"]])
    end

    it "suppresses an automatic allow even when a human authority is exempt" do
      expect(poisoned(ladder(support::Raiser.new("r"), support::Allower.new("a")), exempt: :human)).to be_suppressed
    end
  end

  describe "why_not" do
    # Scenario: why_not names the first refusing rung's reason
    it "is the first refusing rung's reason" do
      expect(ladder(support::Silent.new("s"), support::Denier.new("d")).call(:input).why_not).to eq("d refuses")
    end

    it "is the first reasoned abstention's reason when nothing decided" do
      outcome = ladder(support::Silent.new("s"), support::Explaining.new("first"), support::Explaining.new("second"))
                .call(:input)

      expect(outcome.why_not).to eq("first has a doubt")
    end

    it "is never asked of an abstention when a later rung allows" do
      explaining = support::Explaining.new("e")

      outcome = ladder(explaining, support::Allower.new("a")).call(:input)

      expect([outcome.why_not, explaining.asked]).to eq([nil, 0])
    end

    it "is never asked of a nested abstention when a later rung allows, as flat" do
      explaining = support::Explaining.new("e")

      outcome = ladder(ladder(explaining), support::Allower.new("a")).call(:input)

      expect([outcome.why_not, explaining.asked]).to eq([nil, 0])
    end

    it "carries a nested abstention's reason out when nothing decided" do
      outcome = ladder(ladder(support::Silent.new("s"), support::Explaining.new("inner")), support::Denier.new("d"))
                .call(:input)

      expect(outcome.why_not).to eq("inner has a doubt")
    end

    it "skips an abstention whose reason raises, and never counts it as a fault" do
      broken = support::Explaining.new("broken") { raise support::Boom, "cannot say" }

      outcome = ladder(broken, support::Explaining.new("next"), support::Allower.new("a")).call(:input)
      undecided = ladder(broken, support::Explaining.new("next")).call(:input)

      expect([outcome.allow?, outcome.faulted?]).to eq([true, false])
      expect([undecided.why_not, undecided.faulted?]).to eq(["next has a doubt", false])
    end
  end

  it "is a frozen value whose outcome is deeply frozen" do
    built = ladder(support::Raiser.new("r"), ladder(support::Denier.new("d")))

    expect(built).to be_frozen
    expect(Ractor.shareable?(built.call(:input))).to be(true)
  end

  it "leaves its edge deeply frozen with a reason worked out once" do
    explaining = support::Explaining.new("e")

    outcome = described_class::Poisoning.new(ladder(support::Raiser.new("r"), explaining)).call(:input)

    expect(Ractor.shareable?(outcome)).to be(true)
    expect([outcome.why_not, outcome.why_not, explaining.asked]).to eq(["e has a doubt", "e has a doubt", 1])
  end

  # The chat ladder poisons at the edge of each ladder value, the rules ladder
  # included, so a broken rule's company cannot settle a call a human could.
  describe "inside the chat ladder" do
    let(:journal) { Lain::Journal.new(io: StringIO.new) }
    let(:queue) { Lain::Approval::Parked::Queue.new(journal:, timeout: 1) }
    let(:tools) { Lain::Toolset.new([Lain::Tools::Bash.new]) }
    let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "ls" }) }

    it "parks a call for a human when a rule faults and a later rule allows" do
      chat = Lain::Approval::Escalation.for(queue:, tools:, journal:,
                                            rules: [support::Raising.new, support::Allowing.new])
      parked = nil
      answer = Sync do |task|
        asked = task.async { chat.call(effect, nil) }
        parked = task.with_timeout(1) { queue.dequeue }
        parked.approve(surface: "tty", authority: :human)
        asked.wait
      end

      expect(parked).not_to be_nil
      expect(answer).to be(true)
    end
  end
end
