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

  # The grant is the epic seam's to make: a chat attenuates every child from a
  # floor that holds neither name, so a second role naming one would be a role
  # no ordinary spawn could ever build.
  it "names the spawner and the skill renderer in the issue orchestrator alone" do
    holders = described_class.all.select { |role| role.only.intersect?(%i[subagent run_skill]) }

    expect(holders.map(&:name)).to eq([:issue_orchestrator])
  end
end
