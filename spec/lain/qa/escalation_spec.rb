# frozen_string_literal: true

RSpec.describe Lain::QA::Escalation do
  def sample(verdict:, confidence: 0.9, executed: false)
    Lain::QA::Escalation::Sample.new(verdict:, confidence:, executed:)
  end

  def ran(verdict) = sample(verdict:, executed: true)

  # A rung's fitness to settle a pass is the RUNG's, so it rides beside the risk
  # rather than on each sample: one rung's samples all share it by construction.
  def decide(samples, risk: "medium", strong: false)
    described_class.new.call(samples, risk:, strong:)
  end

  def judged(samples, risk: "low", strong: false, floor: 0.7)
    described_class::Judgement.new(samples:, risk:, strong:, floor:)
  end

  # ---- An exit status is not an opinion, once somebody can be held to it -----

  # The rule that saves the most money: a rung fit to give a verdict that RAN
  # something and watched it fail needs no stronger model to believe it.
  it "reports an executed failure a verdict-holding rung observed" do
    decision = decide([ran("fail"), sample(verdict: "fail")], strong: true)

    expect(decision).to have_attributes(action: :report, rule: "executed-fail")
    expect(decision).to be_report
    expect(decision).not_to be_escalate
  end

  # The asymmetry the first cut left unwritten: a rung whose voice may not accept
  # a pass may not file a blocker on nothing but its own self-reported
  # `executed`, either. `executed` is the model's claim about itself, and a cheap
  # model crying wolf is measured -- one raised 1.75 false alarms per plan
  # review. So a cheap rung needs a second execution agreeing with the first.
  it "escalates a lone executed failure a rung that cannot hold a verdict reported" do
    expect(decide([ran("fail"), sample(verdict: "fail"), sample(verdict: "fail")]).rule)
      .to eq("unconfirmed-fail")
  end

  it "reports an executed failure two cheap samples corroborate" do
    expect(decide([ran("fail"), ran("fail"), sample(verdict: "fail")]).rule)
      .to eq("corroborated-executed-fail")
  end

  # Ordered ahead of the risk rule on purpose: a high-risk card whose failure was
  # OBSERVED is the one case where high risk asks for nothing more.
  it "reports an executed failure on a high-risk criterion from one strong voice" do
    expect(decide([ran("fail")], risk: "high", strong: true).rule).to eq("executed-fail")
  end

  # ---- Risk gates how much corroboration a pass needs, never a veto ---------

  # A high-risk criterion nothing could ever settle would make the gate useless
  # exactly where it matters, so risk buys CORROBORATION rather than an
  # unconditional climb: one voice is not enough, two agreeing voices are.
  it "escalates a high-risk criterion one voice passed, however fit that voice is" do
    expect(decide([sample(verdict: "pass")], risk: "high", strong: true).rule)
      .to eq("risk-high-uncorroborated")
  end

  it "accepts a high-risk criterion two verdict-holding samples agree on" do
    decision = decide([sample(verdict: "pass"), sample(verdict: "pass")], risk: "high", strong: true)

    expect(decision).to have_attributes(action: :accept, rule: "unanimous-pass")
  end

  it "still needs a verdict-holding voice for a corroborated high-risk pass" do
    expect(decide([sample(verdict: "pass")] * 3, risk: "high").rule).to eq("no-strong-voice")
  end

  it "asks a low-risk criterion for no corroboration at all" do
    expect(decide([sample(verdict: "pass")], risk: "low", strong: true).rule).to eq("unanimous-pass")
  end

  # ---- Everything else about a verdict is a reason to climb ----------------

  it "escalates when any sample could not settle the criterion" do
    expect(decide([sample(verdict: "pass"), sample(verdict: "unverified")], strong: true).rule)
      .to eq("unverified")
  end

  it "escalates when the samples disagree" do
    expect(decide([sample(verdict: "pass"), sample(verdict: "fail")], strong: true).rule)
      .to eq("disagreement")
  end

  # A weak model's INFERRED fail costs an implementer a whole fix round, which is
  # more than one ask of a stronger model.
  it "escalates a unanimous failure nobody executed" do
    expect(decide([sample(verdict: "fail")] * 2, strong: true).rule).to eq("unconfirmed-fail")
  end

  it "escalates when nothing was asked at all" do
    expect(decide([]).rule).to eq("nothing-asked")
  end

  # ---- Agreement among cheap models is not enough to accept -----------------

  # MEASURED: one acceptance item was called correct by three cheap models
  # unanimously and caught only by the ones fit to hold a verdict. So unanimity
  # is not the evidence -- unanimity from a voice declared fit to give it is.
  it "escalates a unanimous pass from a rung whose voice cannot settle one" do
    decision = decide([sample(verdict: "pass")] * 3)

    expect(decision).to have_attributes(action: :escalate, rule: "no-strong-voice")
  end

  it "accepts a unanimous pass from a rung whose voice can settle one" do
    decision = decide([sample(verdict: "pass")] * 3, strong: true)

    expect(decision).to have_attributes(action: :accept, rule: "unanimous-pass")
    expect(decision).to be_accept
  end

  it "accepts a single verdict-holding pass, which is what a strong rung asks once for" do
    expect(decide([sample(verdict: "pass")], strong: true).rule).to eq("unanimous-pass")
  end

  it "escalates a verdict-holding pass the samples were not confident about" do
    expect(decide([sample(verdict: "pass", confidence: 0.4), sample(verdict: "pass", confidence: 0.5)],
                  strong: true).rule).to eq("low-confidence")
  end

  it "reads the confidence floor from its construction" do
    lenient = described_class.new(confidence: 0.3)

    expect(lenient.call([sample(verdict: "pass", confidence: 0.4)], risk: "low", strong: true).rule)
      .to eq("unanimous-pass")
  end

  # ---- The rules are the record ---------------------------------------------

  # A spend nobody can audit cannot be tuned, so every decision names the rule
  # that produced it and the whole ordered list is readable -- the QA skill's
  # prose is pinned to it rather than restating it.
  it "cites a rule from its own ordered list on every decision" do
    names = described_class::RULES.map(&:name)

    expect(names).to eq(%w[nothing-asked executed-fail corroborated-executed-fail risk-high-uncorroborated
                           unverified disagreement unconfirmed-fail no-strong-voice low-confidence
                           unanimous-pass])
    expect(names).to include(decide([sample(verdict: "pass")]).rule)
  end

  # The last rule is unconditional, so `#call` can never answer with no rule at
  # all -- a nil rule would reach a report as a decision nobody can explain.
  it "ends in a rule that always matches" do
    expect(described_class::RULES.last.applies.call(judged([]))).to be(true)
  end

  # Every row is PUBLIC and this spec applies them standalone, so no row may rest
  # on `nothing-asked` having run first: an empty set once made two of them raise
  # rather than answer.
  it "answers every rule over an empty sample set without raising" do
    answers = described_class::RULES.map { |rule| rule.applies.call(judged([])) }

    expect(answers).to all(be(true).or(be(false)))
  end

  it "renders a decision as the action and the rule that produced it" do
    expect(decide([sample(verdict: "pass")]).to_s).to eq("escalate (no-strong-voice)")
  end

  it "refuses a risk outside the plan's own set, rather than guessing at one" do
    expect { decide([sample(verdict: "pass")], risk: "catastrophic") }
      .to raise_error(ArgumentError, %r{catastrophic.*low/medium/high})
  end

  # ---- The values -----------------------------------------------------------

  describe "a sample" do
    it "reads an answer" do
      answer = Lain::QA::Answer.parse(<<~REPLY)
        ```qa-answer
        {"verdict":"fail","confidence":0.8,"executed":true,"summary":"s","evidence":"e","reproduction":"r"}
        ```
      REPLY

      expect(Lain::QA::Escalation::Sample.of(answer))
        .to have_attributes(verdict: "fail", confidence: 0.8, executed: true)
    end

    # {Answer} is the one reader of a model's words and already settles an
    # unspelled verdict as `unverified`, so by the time a sample exists the word
    # came from there. A fourth spelling here is a programmer's error, and a
    # second normalisation would be a second definition of "said nothing".
    it "refuses a verdict outside the closed set, rather than normalising it a second time" do
      expect { sample(verdict: "probably fine") }
        .to raise_error(ArgumentError, %r{probably fine.*pass/fail/unverified})
    end

    it "clamps a confidence a model over-claimed, rather than refusing the sample" do
      expect([sample(verdict: "pass", confidence: 5).confidence,
              sample(verdict: "pass", confidence: "lots").confidence]).to eq([1.0, 0.0])
    end

    it "is an executed failure only when it both failed and ran something" do
      expect([ran("fail").executed_fail?, sample(verdict: "fail").executed_fail?,
              ran("pass").executed_fail?]).to eq([true, false, false])
    end

    it "is deeply frozen however it was built, so a caller's String cannot follow it" do
      built = Lain::QA::Escalation::Sample.new(verdict: +"pass", confidence: 0.5, executed: false)

      expect(built).to be_deeply_frozen
      expect(built.with(verdict: +"fail")).to be_deeply_frozen
    end
  end

  # `.new` and `#with` both bypass any factory, so the interning has to sit in
  # the constructor: a member left as the caller's String is reachable mutable
  # state, and a later mutation would follow the decision into a report.
  describe "a decision" do
    it "is deeply frozen however it was built" do
      built = described_class::Decision.new(action: :escalate, rule: +"unanimous-pass")

      expect(built).to be_deeply_frozen
      expect(built.with(rule: +"low-confidence")).to be_deeply_frozen
    end

    it "refuses an action outside the three the ladder acts on" do
      expect { described_class::Decision.new(action: :ponder, rule: "x") }
        .to raise_error(ArgumentError, %r{ponder.*accept/report/escalate})
    end
  end

  describe "a judgement" do
    it "is deeply frozen however it was built" do
      built = judged([sample(verdict: "pass")], risk: +"high")

      expect(built).to be_deeply_frozen
      expect(built.with(risk: +"low")).to be_deeply_frozen
    end

    it "answers a mean confidence of zero over no samples at all" do
      expect(judged([]).mean_confidence).to eq(0.0)
    end

    # The freeze on `samples` is shallow, so freezing is not the same claim as
    # shareable: a member that is not a Sample carries its own mutable state past
    # it, and `#with(samples:)` is the door a frozen-member assertion misses.
    it "refuses samples that are not samples, which would carry mutable state into every row" do
      expect { judged([+"pass"]) }.to raise_error(ArgumentError, /must all be samples/)
    end
  end
end
