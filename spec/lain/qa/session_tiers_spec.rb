# frozen_string_literal: true

require "json"
require "tmpdir"

# A spawn that records the role, mode and model each ask carried. Named so a
# failure says which collaborator stood in, and it takes the `model:` keyword
# the real role-selecting spawn takes, because that keyword is what binds a rung.
class SessionTiersSpawn
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

# The default binding: every rung a QA pass gets when the project has named no
# models of its own.
RSpec.describe Lain::QA::SessionTiers do
  def answer(verdict:)
    body = { "verdict" => verdict, "confidence" => 0.9, "executed" => false,
             "summary" => "#{verdict} on it", "evidence" => "read it", "reproduction" => "rspec x_spec.rb" }
    "Had a look.\n\n```qa-answer\n#{JSON.generate(body)}\n```\n"
  end

  let(:spawn) { SessionTiersSpawn.new(answer(verdict: "pass")) }
  let(:rungs) { described_class.call(spawn) }

  # ONE rung, because there is one model. A second rung over the same model
  # would be a same-model retry, which the measured evidence rules out and which
  # the Ladder refuses outright.
  it "binds one rung, since one model is one rung" do
    expect(rungs.map(&:tier)).to eq(["t2"])
  end

  it "names no model, so the rung runs on whatever the session runs on" do
    expect(rungs.map(&:model)).to eq([Lain::Tools::Subagent::ModelChoice::Null.model])
  end

  # The sampling discipline survives the missing cost gradient: three
  # independent asks still catch disagreement and an executed failure.
  it "takes three samples, so agreement is still measured" do
    expect(rungs.map(&:samples)).to eq([3])
  end

  # The docstring says plainly that nothing here can measure the session model's
  # fitness, so declaring it fit to settle a pass would re-enter the measured
  # hazard through the default -- on the one rung where naming no model means no
  # guard could inspect it either. A pass that accepts is not worth more than a
  # pass that is honest.
  it "declares its one rung unfit to settle a pass, since it cannot measure one" do
    expect(rungs.map(&:strong?)).to eq([false])
  end

  it "asks the qa role on a fresh context, so no sample reads another's reasoning" do
    Lain::QA::Ladder.new(rungs:, brief: "the brief").call([criterion])

    expect(spawn.asks.map { |ask| [ask.role, ask.mode] }).to eq([%i[qa fresh]] * 3)
  end

  it "takes the role, so a caller may bind the ladder to one of its own" do
    Lain::QA::Ladder.new(rungs: described_class.call(spawn, role: :reviewer_code), brief: "b").call([criterion])

    expect(spawn.asks.map(&:role).uniq).to eq([:reviewer_code])
  end

  it "builds rungs the ladder accepts" do
    expect(Lain::QA::Ladder.new(rungs:, brief: "the brief").call([criterion]).tiers_run).to eq(["t2"])
  end

  # AC-shaped and deliberate: with no model named, every criterion comes back
  # owing a manual pass. That is the guarantee that survives the missing
  # gradient, and the reason a project binds its own tiers.
  it "leaves a unanimous confident pass unsettled, because no voice here may settle one" do
    report = Lain::QA::Ladder.new(rungs:, brief: "the brief").call([criterion]).report(subject: "plan.md")

    expect(report.verdict).to eq(:unsettled)
    expect(report).not_to be_clean
    expect(report.unsettled).to eq(["T1"])
  end

  # A pass no rung could settle is unsettled and never a pass, exactly as it is
  # on a bound ladder -- which is the whole reason this default exists rather
  # than a pass that skips QA.
  it "leaves a criterion its one rung could not settle unsettled" do
    silent = Lain::QA::Ladder.new(rungs: described_class.call(SessionTiersSpawn.new("")), brief: "b")

    expect(silent.call([criterion]).unsettled).to eq(["T1"])
  end

  # ---- Through the real spawn, with nothing doubled between ----------------

  describe "over the role-selecting spawn the chat really holds" do
    let(:store) { Lain::Store.new }
    let(:parent) { Lain::Timeline.empty(store:) }
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

    it "asks the session's own model and comes back owing a manual pass" do
      provider = Lain::Provider::Mock.new(responses: Array.new(3) { text_response(answer(verdict: "pass")) })
      real = Lain::Skill::RoleSpawn.new(provider:, context_factory: -> { child_context }, toolset: union,
                                        parent:, slots: @slots, tool_middleware: ToolRegistry::UNGUARDED)

      climb = Lain::QA::Ladder.new(rungs: described_class.call(real, role: :reviewer_code), brief: "the brief")
                              .call([criterion])

      expect(provider.call_count).to eq(3)
      expect(provider.last_request.model).to eq("the-session-model")
      expect(climb.report(subject: "plan.md").verdict).to eq(:unsettled)
    end
  end

  def criterion
    scenario = Lain::Gherkin::Criteria.parse(<<~BLOCK).first
      ```gherkin
      Scenario: T1
        Given a thing
        Then it holds
      ```
    BLOCK
    Lain::QA::Ladder::Criterion.new(id: "T1", scenario:, risk: "medium")
  end
end
