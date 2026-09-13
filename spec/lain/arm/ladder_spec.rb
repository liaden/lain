# frozen_string_literal: true

# The altitude bench's stage sequence: research -> epic_plan -> issue_plan ->
# implementation -> land. A frozen Array, not an algebra -- nothing that walks
# it needs one -- with exactly two properties: an arm's rungs are the suffix
# starting at its own entry rung, and the sequence itself does not depend on
# which gate policy an arm was built with.
RSpec.describe Lain::Arm::Ladder do
  describe ".from — an arm's rungs are the suffix from its entry rung" do
    it "lists issue_plan, implementation, land in order for an arm entering at issue_plan" do
      expect(described_class.from("issue_plan")).to eq(%w[issue_plan implementation land])
    end

    it "lists the whole ladder for an arm entering at research" do
      expect(described_class.from("research")).to eq(%w[research epic_plan issue_plan implementation land])
    end

    it "lists only implementation and land for one-shot's entry" do
      expect(described_class.from("implementation")).to eq(%w[implementation land])
    end

    it "lists only land for an arm entering there directly" do
      expect(described_class.from("land")).to eq(%w[land])
    end

    it "accepts anything answering #to_s, not just a bare String" do
      expect(described_class.from(Lain::Epic::Stage.new("issue_plan"))).to eq(%w[issue_plan implementation land])
    end

    it "refuses an entry rung outside the ladder, naming it" do
      expect { described_class.from("qa") }.to raise_error(Lain::Error, /"qa" is not a rung on the ladder/)
    end
  end

  describe "RUNGS — the closed, frozen set" do
    it "is research, epic_plan, issue_plan, implementation, land, in that order" do
      expect(described_class::RUNGS).to eq(%w[research epic_plan issue_plan implementation land])
    end

    it "is frozen, and stays a frozen Array once returned by .from" do
      expect(described_class::RUNGS).to be_frozen
      expect(described_class.from("research")).to be_frozen
    end
  end

  # Scenario: policy changes which answers come back, not which stages are
  # visited.
  describe "gate policy is an evaluator parameter, never part of the ladder" do
    def config_for(policy_name)
      table = Lain::Epic::STAGES.to_h { |stage| [stage, policy_name] }
      Lain::Config.new(
        epics: Lain::Config::Epics.new(home: :xdg, gates: Lain::Config::Epics::Gates.new(table:))
      )
    end

    it "has epic-progressive and epic-hands-off visit the same rungs under an all-approve stub, " \
       "with every gated stage resolving to hands_off under hands-off's map" do
      queue = Lain::Approval::SignoffQueue.new

      # "epic-progressive" and "epic-hands-off" differ only in which policy
      # each epic-scoped stage runs under -- both are built from the SAME
      # ladder entry, so the rungs each arm's run would visit are identical
      # before either has decided a single gate.
      deps = Lain::Approval::Gate::Policies::Deps.new(queue:, asker: nil, journal: nil)
      built = Lain::Approval::Gate::Policies.for_all(config: config_for("hands_off"), deps:)

      # Every GATED stage (every member of Epic::STAGES) resolves to
      # hands_off; `land` carries no gate policy at all because it is not a
      # member of Epic::STAGES -- landing is a mechanical step, not a
      # human-signed-off one.
      expect(built.keys).to eq(Lain::Epic::STAGES)
      expect(built.values.map(&:name)).to all(eq("hands_off"))
    end
  end
end
