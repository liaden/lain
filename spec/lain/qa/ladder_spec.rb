# frozen_string_literal: true

require "json"

# A spawn that records what each rung asked it, answering every ask with the
# same reply. Named rather than anonymous so a failure message says which
# collaborator stood in, and it takes the `model:` keyword the real
# role-selecting spawn takes, because that keyword is what binds a rung.
class LadderRecordingSpawn
  Ask = Struct.new(:role, :mode, :prompt, :model, keyword_init: true)

  attr_reader :asks

  def initialize(reply)
    @reply = reply
    @asks = []
  end

  def call(role, mode, prompt, model: Lain::Tools::Subagent::ModelChoice::Null)
    @asks << Ask.new(role:, mode:, prompt:, model: model.model)
    Lain::Tool::Result.ok(@reply)
  end
end

# A provider whose endpoint is already held by somebody else, so the gate
# refuses this caller before anything reaches the wire.
class LadderBusyProvider < Lain::Provider::Mock
  def complete(*, **)
    raise Lain::Provider::Admission::Busy, "ollama at http://127.0.0.1:11434 is busy"
  end
end

RSpec.describe Lain::QA::Ladder do
  let(:asked) { [] }

  def reply(verdict:, confidence: 0.9, executed: false, evidence: "ran the spec", reproduction: "rspec x_spec.rb")
    body = { "verdict" => verdict, "confidence" => confidence, "executed" => executed,
             "summary" => "#{verdict} on it", "evidence" => evidence, "reproduction" => reproduction }
    "Had a look.\n\n```qa-answer\n#{JSON.generate(body)}\n```\n"
  end

  def passing = reply(verdict: "pass")
  def executed_fail = reply(verdict: "fail", executed: true)

  def choice(model) = Lain::Tools::Subagent::ModelChoice.of(model, declared_by: "the ladder's binding")

  def scenario(name)
    Lain::Gherkin::Criteria.parse(<<~BLOCK).first
      ```gherkin
      Scenario: #{name}
        Given a thing
        Then it holds
      ```
    BLOCK
  end

  def criterion(id, risk: "medium") = described_class::Criterion.new(id:, scenario: scenario(id), risk:)

  # `reply` may be a String or a callable, so one helper serves a fixed answer
  # and a rung that behaves differently per ask.
  def rung(tier, answer: passing, model: nil, **rest)
    recorder = asked
    described_class::Rung.new(tier:, model: model || choice("model-#{tier}"), **rest,
                              ask: lambda do |prompt|
                                recorder << [tier, prompt]
                                answer.respond_to?(:call) ? answer.call(prompt) : answer
                              end)
  end

  def ladder(rungs, brief: "the QA brief and the changeset", **rest)
    described_class.new(rungs:, brief:, **rest)
  end

  def tiers_asked = asked.map(&:first)

  # ---- The cheap rung runs first, and one model swap serves every criterion --

  # BREADTH-FIRST BY RUNG. On one GPU a model swap costs the better part of a
  # minute, so a per-criterion climb would pay it twice per escalation.
  it "asks every criterion at the cheap rung before any is asked at the strong rung" do
    criteria = (1..12).map { |number| criterion("T#{number}") }

    ladder([rung("t1", samples: 3), rung("t2", strong: true)]).call(criteria)

    expect(tiers_asked).to eq((["t1"] * 36) + (["t2"] * 12))
  end

  it "reports which rungs it really ran, in the ladder's own order" do
    climb = ladder([rung("t1", samples: 3), rung("t2", strong: true)]).call([criterion("T1")])

    expect(climb.tiers_run).to eq(%w[t1 t2])
  end

  it "never re-checks a criterion the cheap rung accepted" do
    ladder([rung("t1", samples: 3, strong: true), rung("t2", strong: true)]).call([criterion("T1")])

    expect(tiers_asked).to eq(%w[t1 t1 t1])
  end

  it "opens every ask with the brief and names the rung, the criterion and its risk" do
    ladder([rung("t1", strong: true)]).call([criterion("T1", risk: "high")])

    expect(asked.first.last).to include("the QA brief and the changeset", "t1", "T1", "high", "Scenario: T1")
  end

  # ---- A silent rung escalates rather than scoring --------------------------

  it "escalates a rung that answered nothing at all, naming the emptiness" do
    climb = ladder([rung("t1", answer: "   "), rung("t2", strong: true)]).call([criterion("T1")])

    expect(climb.escalations.first).to include("escalate (unverified)", described_class::EMPTY_REPLY)
    expect(tiers_asked).to eq(%w[t1 t2])
  end

  # A token cap is the commonest way a small model stops, and it stops INSIDE
  # the fence -- where the reader would otherwise fall back to an earlier block
  # and score the prompt's own template as an answer.
  it "escalates a rung whose reply stopped inside its answer block, naming the length" do
    cut = "Thinking about it.\n\n```qa-answer\n{\"verdict\":\"pass\",\"confidence\":0.9"

    climb = ladder([rung("t1", answer: cut), rung("t2", strong: true)]).call([criterion("T1")])

    expect(climb.escalations.first).to include("escalate (unverified)", "stopped inside", "characters")
    expect(tiers_asked).to eq(%w[t1 t2])
  end

  # THE MEASURED RULE: only one model converted a bigger budget into an answer,
  # and that answer found 6% of the planted bugs. So a truncated rung climbs to
  # a DIFFERENT model, and the ladder's one-model-per-rung refusal is what makes
  # that the only thing it can do.
  it "climbs to a different model rather than asking the same one again" do
    ladder([rung("t1", answer: ""), rung("t2", strong: true)]).call([criterion("T1")])

    expect(asked.map(&:first)).to eq(%w[t1 t2])
  end

  # ---- An executed failure is reported without climbing --------------------

  it "reports a failure a rung executed without spending the stronger model" do
    climb = ladder([rung("t1", answer: executed_fail, samples: 3, strong: true), rung("t2", strong: true)])
            .call([criterion("T1")])

    expect(tiers_asked).to eq(%w[t1 t1 t1])
    expect(climb.findings.map { |finding| [finding.severity, finding.criterion, finding.tier] })
      .to eq([%w[major T1 t1]])
    expect(climb.escalations.first).to include("report (executed-fail)")
  end

  # THE CARDS A QA GATE EXISTS FOR ARE THE HIGH-RISK ONES, so a ladder strong
  # enough to corroborate one must be able to conclude on it. An earlier cut
  # escalated every high-risk criterion unconditionally: every rung spent, every
  # sample discarded, and a manual pass owed however good the ladder was.
  it "settles a high-risk criterion a verdict-holding rung corroborates" do
    climb = ladder([rung("t1", samples: 3), rung("t2", samples: 2, strong: true)])
            .call([criterion("H1", risk: "high")])

    expect(climb.unsettled).to be_empty
    expect(climb.findings).to be_empty
    expect(climb.escalations.last).to include("accept (unanimous-pass)")
  end

  it "still asks a high-risk criterion for more than one voice" do
    climb = ladder([rung("t1", samples: 1, strong: true)]).call([criterion("H1", risk: "high")])

    expect(climb.escalations.first).to include("escalate (risk-high-uncorroborated)")
    expect(climb.unsettled).to eq(["H1"])
  end

  it "reports a high-risk criterion's executed failure as a blocker" do
    climb = ladder([rung("t1", answer: executed_fail, strong: true)]).call([criterion("T1", risk: "high")])

    expect(climb.findings.map(&:severity)).to eq(["blocker"])
    expect(climb.findings.first).to be_holds
  end

  # A fail with no evidence or no reproduction is the weak-model false positive
  # the ladder exists to keep away from an implementer, so it is not a finding
  # and the stronger rung decides instead.
  it "climbs rather than filing an executed failure that carries no reproduction" do
    unfalsifiable = reply(verdict: "fail", executed: true, reproduction: "  ")

    climb = ladder([rung("t1", answer: unfalsifiable, strong: true), rung("t2", strong: true)])
            .call([criterion("T1")])

    expect(tiers_asked).to eq(%w[t1 t2])
    expect(climb.findings).to be_empty
  end

  # ---- A criterion nothing could settle is a minor finding -----------------

  it "carries a criterion no rung could settle as a minor finding, never as a pass" do
    climb = ladder([rung("t1", answer: "")]).call([criterion("T1")])
    report = climb.report(subject: "planning/specs/plan.md")

    expect(climb.unsettled).to eq(["T1"])
    expect(climb.findings.map { |finding| [finding.severity, finding.criterion] }).to eq([%w[minor T1]])
    expect(report.verdict).to eq(:unsettled)
    expect(report).not_to be_clean
    expect(report.to_markdown).to include("PASS (1 unsettled)", "## Unsettled criteria", "- T1")
  end

  it "reproduces an unsettled criterion by quoting the scenario nobody could settle" do
    climb = ladder([rung("t1", answer: "")]).call([criterion("T1")])

    expect(climb.findings.first.reproduction).to include("Scenario: T1", "Given a thing")
    expect(climb.findings.first.evidence).to include(described_class::EMPTY_REPLY)
  end

  it "hands the report the escalations and the rungs it ran, so a pass can be audited" do
    climb = ladder([rung("t1"), rung("t2", strong: true)]).call([criterion("T1")])
    report = climb.report(subject: "planning/specs/plan.md")

    expect(report.tiers_run).to eq(%w[t1 t2])
    expect(report.escalations).to eq(climb.escalations)
    expect(report).to be_clean
  end

  # ---- Budgets are per rung, and a spent rung half-scores nothing ----------

  it "leaves a criterion for the next rung when this one cannot afford a full sample set" do
    climb = ladder([rung("t1", samples: 3, budget: 4), rung("t2", strong: true)])
            .call([criterion("T1"), criterion("T2")])

    expect(tiers_asked).to eq(%w[t1 t1 t1 t2 t2])
    expect(climb.escalations.grep(/T2.*t1/).first).to include("budget")
  end

  it "spends a fresh budget on every pass, so one ladder can be run twice" do
    reusable = ladder([rung("t1", samples: 3, budget: 3, strong: true)])

    reusable.call([criterion("T1")])
    reusable.call([criterion("T2")])

    expect(tiers_asked).to eq(%w[t1 t1 t1 t1 t1 t1])
  end

  # ---- Bounded against the admission gate, not only against its own budget --

  # A wall bound is the CALLER's number: the admission gate's 300s is a
  # per-acquire wait, not a pass budget, and the gate keeps no queue, so stopping
  # a pass at any particular wall time protects no caller who arrived later.
  # The clock ADVANCES, and by more than any finite default could survive: a
  # constant clock cannot tell an unbounded pass from a bounded one, so the
  # example would pass with a borrowed 300s default restored -- which is the one
  # thing it exists to notice.
  it "puts no wall-clock bound on a pass the caller did not ask for" do
    now = 0.0
    ticking = ladder([rung("t1", strong: true)], clock: -> { now += 1_000_000.0 })

    expect(ticking.call([criterion("T1"), criterion("T2")]).unsettled).to be_empty
    expect(described_class::UNBOUNDED).to eq(Float::INFINITY)
  end

  it "stops asking once the pass has outlasted a deadline the caller stated" do
    times = [0.0, 1.0, 400.0]
    climb = ladder([rung("t1", strong: true)], deadline: 300, clock: -> { times.shift || 400.0 })
            .call([criterion("T1"), criterion("T2")])

    expect(tiers_asked).to eq(%w[t1])
    expect(climb.unsettled).to eq(["T2"])
    expect(climb.escalations.last).to include("deadline")
  end

  # Each ask can itself block for a whole acquire deadline, so a clock read once
  # per sample SET can overrun the pass bound several times over. Read between
  # samples, and discard a set that ran out half way -- which is the same
  # unsettled answer a spent budget gives, and never a half-scored criterion.
  it "reads the clock between samples and half-scores nothing when it runs out mid-set" do
    times = [0.0, 1.0, 2.0, 400.0]
    climb = ladder([rung("t1", samples: 3, strong: true)], deadline: 300,
                                                           clock: -> { times.shift || 400.0 }).call([criterion("T1")])

    expect(tiers_asked).to eq(%w[t1 t1])
    expect(climb.unsettled).to eq(["T1"])
    expect(climb.escalations.last).to include("deadline")
  end

  it "reads a busy endpoint as a rung that could not answer, rather than losing the pass" do
    busy = ->(_prompt) { raise Lain::Provider::Admission::Busy, "ollama at 127.0.0.1:11434 is busy" }

    climb = ladder([rung("t1", answer: busy), rung("t2", strong: true)]).call([criterion("T1")])

    expect(climb.escalations.first).to include("ollama at 127.0.0.1:11434 is busy")
    expect(climb.findings).to be_empty
  end

  # Sequential BY CONSTRUCTION: a pass whose own samples overlapped would queue
  # against itself at the gate, which is the pathology the deadline above only
  # reports.
  it "never has two asks in flight at once" do
    depth = 0
    peak = 0
    watched = lambda do |_prompt|
      depth += 1
      peak = [peak, depth].max
      depth -= 1
      passing
    end

    ladder([rung("t1", answer: watched, samples: 3, strong: true)]).call([criterion("T1"), criterion("T2")])

    expect(peak).to eq(1)
  end

  # ---- Each rung is bound to its own model --------------------------------

  describe "a rung built over the role-selecting spawn" do
    let(:spawn) { LadderRecordingSpawn.new(passing) }

    def spawning(tier, model, **rest)
      described_class::Rung.spawning(tier:, role_spawn: spawn, role: :qa, model: choice(model), **rest)
    end

    it "answers each rung's asks with that rung's own model" do
      ladder([spawning("t1", "laguna-xs-2.1", samples: 2), spawning("t2", "qwen3.8:27b", strong: true)])
        .call([criterion("T1")])

      expect(spawn.asks.map(&:model)).to eq(["laguna-xs-2.1", "laguna-xs-2.1", "qwen3.8:27b"])
    end

    # A fresh chain per ask, so no rung reads another rung's reasoning and the
    # samples are independent rather than an echo.
    it "asks the named role on a fresh context every time" do
      ladder([spawning("t1", "laguna-xs-2.1", samples: 2, strong: true)]).call([criterion("T1")])

      expect(spawn.asks.map { |ask| [ask.role, ask.mode] }).to eq([%i[qa fresh], %i[qa fresh]])
    end

    it "names the model that answered in every escalation it records" do
      climb = ladder([spawning("t1", "laguna-xs-2.1"), spawning("t2", "qwen3.8:27b", strong: true)])
              .call([criterion("T1")])

      expect(climb.escalations.first).to include("laguna-xs-2.1")
    end

    it "says whose model answered when no rung named one" do
      climb = ladder([described_class::Rung.spawning(tier: "t1", role_spawn: spawn, role: :qa)])
              .call([criterion("T1")])

      expect(climb.escalations.first).to include(described_class::Rung::UNNAMED)
    end
  end

  # Nothing doubled between the ladder and the provider: the rungs' models reach
  # the wire through the real role-selecting spawn, which is the channel a rung
  # is bound by.
  describe "over the real role-selecting spawn" do
    let(:store) { Lain::Store.new }
    let(:child_context) { Lain::Context.new(model: "the-session-model", max_tokens: 256) }
    let(:union) do
      Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new,
                         Lain::Tools::Glob.new, Lain::Tools::Grep.new])
    end

    around do |example|
      Dir.mktmpdir do |root|
        @slots = Lain::Prompt::Slots.load(root:)
        example.run
      end
    end

    # Nothing between the gate and the ladder: the refusal is raised by a real
    # Provider inside a real spawn, and still reads as a rung that could not
    # answer rather than as a pass that died.
    it "survives the admission gate refusing a real provider mid-pass" do
      real = Lain::Skill::RoleSpawn.new(provider: LadderBusyProvider.new(responses: []),
                                        context_factory: -> { child_context }, toolset: union,
                                        parent: Lain::Timeline.empty(store:), slots: @slots,
                                        tool_middleware: ToolRegistry::UNGUARDED)
      rungs = [described_class::Rung.spawning(tier: "t1", role_spawn: real, role: :reviewer_code,
                                              model: choice("laguna-xs-2.1"))]

      climb = ladder(rungs).call([criterion("T1")])

      expect(climb.escalations.first).to include("escalate (unverified)", "is busy")
      expect(climb.unsettled).to eq(["T1"])
    end

    it "answers each rung's asks on that rung's own model, and none on the run's" do
      provider = Lain::Provider::Mock.new(responses: Array.new(2) { text_response(passing) })
      real = Lain::Skill::RoleSpawn.new(provider:, context_factory: -> { child_context },
                                        toolset: union, parent: Lain::Timeline.empty(store:),
                                        slots: @slots, tool_middleware: ToolRegistry::UNGUARDED)
      rungs = [described_class::Rung.spawning(tier: "t1", role_spawn: real, role: :reviewer_code,
                                              model: choice("laguna-xs-2.1")),
               described_class::Rung.spawning(tier: "t2", role_spawn: real, role: :reviewer_code,
                                              model: choice("qwen3.8:27b"), strong: true)]

      ladder(rungs).call([criterion("T1")])

      expect(provider.requests.map(&:model)).to eq(["laguna-xs-2.1", "qwen3.8:27b"])
      expect(child_context.model).to eq("the-session-model")
    end
  end

  # ---- What the ladder refuses to be built as ------------------------------

  describe "refusals" do
    it "refuses a ladder with no rung at all, which could settle nothing" do
      expect { ladder([]) }.to raise_error(described_class::Misbuilt, /no rung/)
    end

    it "refuses a blank brief, which would ask a rung nothing" do
      expect { ladder([rung("t1")], brief: " ") }.to raise_error(described_class::Misbuilt, /brief/)
    end

    # The same model on two rungs is a same-model retry wearing a ladder's
    # clothes, and the measurement is explicit that a rung must climb to a
    # DIFFERENT model.
    it "refuses two rungs bound to the same model, naming who bound it" do
      expect { ladder([rung("t1", model: choice("laguna-xs-2.1")), rung("t2", model: choice("laguna-xs-2.1"))]) }
        .to raise_error(described_class::Misbuilt,
                        /same model.*laguna-xs-2\.1, declared by the ladder's binding/)
    end

    # Two rungs that name NO model cannot be shown to differ, so they are refused
    # on the same rule -- and in words of their own, because "the same model (the
    # run's own model)" reads as though the reader had bound something so named.
    it "refuses two rungs that both leave the model unnamed, in words about silence" do
      unnamed = ->(tier) { described_class::Rung.new(tier:, ask: ->(_prompt) { passing }) }

      expect { ladder([unnamed.call("t1"), unnamed.call("t2")]) }
        .to raise_error(described_class::Misbuilt, /named no model/)
      expect(described_class::UNNAMED_TWICE).not_to include(described_class::Rung::UNNAMED)
    end

    it "refuses rungs out of cheapest-first order, so the cheap rung cannot be second" do
      expect { ladder([rung("t2"), rung("t1")]) }
        .to raise_error(described_class::Misbuilt, /order/)
    end

    it "refuses the same rung twice" do
      expect { ladder([rung("t1", model: choice("a")), rung("t1", model: choice("b"))]) }
        .to raise_error(described_class::Misbuilt, /t1/)
    end

    it "refuses the structural rung, which spends no model and is not the ladder's to run" do
      expect { rung("t0") }.to raise_error(described_class::Misbuilt, /t0/)
    end

    it "refuses a rung outside the ladder's own tiers" do
      expect { rung("t9") }.to raise_error(described_class::Misbuilt, %r{t9.*t0/t1/t2/t3})
    end

    it "refuses a rung that cannot afford one criterion's samples out of its whole budget" do
      expect { rung("t1", samples: 3, budget: 2) }.to raise_error(described_class::Misbuilt, /budget/)
    end

    it "refuses a rung that would take no sample at all" do
      expect { rung("t1", samples: 0) }.to raise_error(described_class::Misbuilt, /samples/)
    end

    it "refuses a criterion with no id, which no finding could cite" do
      expect { described_class::Criterion.new(id: " ", scenario: scenario("x"), risk: "low") }
        .to raise_error(described_class::Misbuilt, /id/)
    end

    it "refuses a criterion whose risk is outside the plan's own set" do
      expect { criterion("T1", risk: "spicy") }
        .to raise_error(described_class::Misbuilt, %r{spicy.*low/medium/high})
    end
  end

  # ---- The values --------------------------------------------------------

  # `.new` and `#with` bypass every factory, so a member left as the caller's
  # object is reachable mutable state that follows the value wherever it goes.
  describe "the values, through the public constructors" do
    let(:finding) do
      Lain::QA::Finding.new(severity: "minor", criterion: "T1", tier: "t1", summary: "s",
                            evidence: "e", reproduction: "r")
    end

    it "answers a deeply frozen criterion" do
      built = described_class::Criterion.new(id: +"T1", scenario: scenario("T1"), risk: +"low")

      expect(built).to be_deeply_frozen
      expect(built.with(id: +"T2")).to be_deeply_frozen
    end

    # A scenario is the one member this cannot intern its way out of, so the
    # shareability is REQUIRED rather than repaired: an unshareable one would
    # take the whole criterion, and the climb quoting it, with it.
    it "refuses a scenario that carries reachable mutable state" do
      mutable = Struct.new(:name).new(+"T1")

      expect { described_class::Criterion.new(id: "T1", scenario: mutable, risk: "low") }
        .to raise_error(described_class::Misbuilt, /scenario/)
    end

    it "answers a deeply frozen climb" do
      built = described_class::Climb.new(findings: [finding], escalations: [+"a line"],
                                         tiers_run: [+"t1"], unsettled: [+"T1"])

      expect(built).to be_deeply_frozen
      expect(built.with(unsettled: [+"T2"])).to be_deeply_frozen
    end

    # A non-Finding here is not merely wrong, it is unshareable -- {Report}
    # refuses one for the same reason, and a climb that let one through would
    # hand the report a value it then has to refuse.
    it "refuses findings that are not findings" do
      expect do
        described_class::Climb.new(findings: [+"a defect, honest"], escalations: [], tiers_run: [],
                                   unsettled: [])
      end
        .to raise_error(described_class::Misbuilt, /finding/)
    end

    it "answers a deeply frozen climb from a real pass" do
      expect(ladder([rung("t1", strong: true)]).call([criterion("T1")])).to be_deeply_frozen
    end
  end
end
