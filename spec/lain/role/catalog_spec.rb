# frozen_string_literal: true

RSpec.describe Lain::Role::Catalog do
  describe "the issue orchestrator" do
    let(:role) { described_class.fetch(:issue_orchestrator) }

    # A whole plan runs inside one of these: it implements as dev does, fans
    # the work out to children, and renders the plan's skill back to itself.
    it "holds the dev tools, the spawner and the skill renderer, and nothing else" do
      expect(role.only).to match_array(described_class.fetch(:dev).only + %i[subagent run_skill])
    end

    # Its shell reaches the session's approval gate exactly as dev's does, so
    # it claims no guarantee that it answers with nobody minding it.
    it "is attended, as dev is" do
      expect(role.unattended).to be(false)
    end

    it "ships the role slot its framing renders from" do
      expect(Lain::Prompt::Slots.shipped_role_templates).to have_key(role.name.to_s)
    end
  end

  describe "the evidence researcher" do
    it "reads, searches and fetches only, and runs unattended" do
      role = described_class.fetch(:evidence_researcher)

      expect(role.only).to contain_exactly(:read_file, :list_files, :glob, :grep, :web_fetch, :web_search)
      expect(role.unattended).to be(true)
    end
  end

  describe "the researcher" do
    it "searches the tree beside reading and fetching" do
      expect(described_class.fetch(:researcher).only).to include(:grep, :glob, :read_file, :list_files)
    end

    it "is told it works to an iteration budget and writes findings as text as it goes" do
      framing = Lain::Prompt::Slots.shipped_role_templates.fetch("researcher")

      expect(framing).to include("iteration budget")
      expect(framing).to include("findings as text as you go")
    end
  end

  # The slot loader refuses a file for each of these, and the role renders
  # sealed; one declaration keeps the two lists from drifting.
  it "derives the approval roles from the roles that render sealed" do
    expect(described_class.approval_roles).to eq(described_class.all.select(&:sealed).map(&:name))
    expect(described_class.approval_roles).to contain_exactly(:auto_approver, :gate_adjudicator, :evidence_researcher)
  end

  # The grant is the epic seam's to make: a chat attenuates every child from a
  # floor that holds neither name, so a second role naming one would be a role
  # no ordinary spawn could ever build.
  it "names the spawner and the skill renderer in the issue orchestrator alone" do
    holders = described_class.all.select { |role| role.only.intersect?(%i[subagent run_skill]) }

    expect(holders.map(&:name)).to eq([:issue_orchestrator])
  end
end
