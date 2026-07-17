# frozen_string_literal: true

RSpec.describe Lain::Skill do
  subject(:skill) do
    described_class.new(
      name: "create-plan",
      description: "Build an orchestrator-ready TDD plan.",
      scaffold: "## Scaffold\n\nDo the thing.\n",
      slots: %w[system task],
      includes: %w[house-style]
    )
  end

  describe "the value it carries" do
    it "keeps the name as a Symbol (the catalog key)" do
      expect(skill.name).to eq(:"create-plan")
    end

    it "keeps the description and raw scaffold verbatim" do
      expect(skill.description).to eq("Build an orchestrator-ready TDD plan.")
      expect(skill.scaffold).to eq("## Scaffold\n\nDo the thing.\n")
    end

    it "normalizes declared slots and includes to frozen Symbol lists" do
      expect(skill.slots).to eq(%i[system task])
      expect(skill.includes).to eq(%i[house-style])
      expect(skill.slots).to be_frozen
      expect(skill.includes).to be_frozen
    end

    it "defaults slots and includes to empty" do
      bare = described_class.new(name: "triage", description: "d", scaffold: "s")
      expect(bare.slots).to eq([])
      expect(bare.includes).to eq([])
    end
  end

  describe "config, not behavior (the explicit boundary)" do
    it "is deeply frozen and Ractor.shareable" do
      expect(skill).to be_frozen
      expect(skill).to be_ractor_shareable
    end

    it "exposes no method that renders, spawns, or calls an agent" do
      %i[call render spawn perform invoke attenuate prelude prelude_segments spawn_policy].each do |behavior|
        expect(skill).not_to respond_to(behavior)
      end
    end
  end
end
