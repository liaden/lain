# frozen_string_literal: true

RSpec.describe Lain::Budget::Table do
  subject(:table) { described_class.new }

  describe "#iterations" do
    it "gives create-epic-issues on a 33-issue epic room for its plan" do
      expect(table.iterations(skill: "create-epic-issues", issues: 33)).to eq(124)
    end

    it "gives the other epic skills 25 plus 3 per issue" do
      expect(%w[iterate-epic implement-epic].map { |skill| table.iterations(skill:, issues: 10) }).to eq([55, 55])
    end

    it "gives plan-epic a flat 60, however many issues the epic holds" do
      expect([table.iterations(skill: "plan-epic"), table.iterations(skill: "plan-epic", issues: 9)]).to eq([60, 60])
    end

    it "reads a role's row when no skill is named" do
      expect([table.iterations(role: :researcher), table.iterations(role: "issue_orchestrator")]).to eq([60, 200])
    end

    it "falls to the default for a name it has no row for, and for no name at all" do
      expect([table.iterations(skill: "greet"), table.iterations]).to eq([25, 25])
    end

    it "lets a configured row replace a default one and leaves the rest" do
      configured = described_class.new(rows: { "plan-epic" => 80, "implement-epic" => { base: 30, per_issue: 4 } })

      expect([configured.iterations(skill: "plan-epic"), configured.iterations(skill: "implement-epic", issues: 5),
              configured.iterations(skill: "iterate-epic", issues: 1)]).to eq([80, 50, 28])
    end

    it "refuses a per-issue row with a key beyond base and per_issue" do
      expect { described_class.new(rows: { "iterate-epic" => { base: 5, per_issue: 1, extra: 2 } }) }
        .to raise_error(ArgumentError, /iterate-epic/)
    end

    it "refuses a row that is not a positive whole number of iterations" do
      expect { described_class.new(rows: { "plan-epic" => 0 }) }.to raise_error(ArgumentError, /plan-epic/)
    end
  end

  describe "#named?" do
    it "is true for a skill with a row and false for one without" do
      expect([table.named?("plan-epic"), table.named?("greet"), table.named?("default")]).to eq([true, false, false])
    end
  end
end

RSpec.describe Lain::Budget::Allowance do
  let(:table) { Lain::Budget::Table.new }

  it "grants a skill with a row the iterations its epic's size earns" do
    allowance = described_class.new(table:, issues: -> { 33 })

    expect(allowance.grant("create-epic-issues")).to eq(iterations: 124)
  end

  it "counts the issues when the skill starts, not when the allowance was built" do
    count = 1
    allowance = described_class.new(table:, issues: -> { count })
    count = 2

    expect(allowance.grant("implement-epic")).to eq(iterations: 31)
  end

  it "grants a skill with no row, and a plain line, the default row" do
    allowance = described_class.new(table: Lain::Budget::Table.new(rows: { "default" => 30 }), issues: -> { 33 })

    expect([allowance.grant("greet"), allowance.grant]).to eq([{ iterations: 30 }, { iterations: 30 }])
  end

  it "grants nothing at all when none is wired" do
    expect(described_class::NONE.grant("plan-epic")).to eq({})
  end
end
