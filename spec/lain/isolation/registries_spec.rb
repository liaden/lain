# frozen_string_literal: true

RSpec.describe Lain::Isolation::Registries do
  subject(:registries) { described_class.new(worktrees, clones) }

  let(:entry) { ->(path) { Lain::Isolation::Worktree::Registry::Entry.new(path:, head: "", branch: "", lock: nil, seal: "") } }
  let(:worktrees) do
    instance_double(Lain::Isolation::Worktree::Registry, entries: [entry.call("/w")], remove: :worktree_removed,
                                                         uncommitted?: false)
  end
  let(:clones) do
    instance_double(Lain::Isolation::Clone::Registry, entries: [entry.call("/c")], remove: :clone_removed,
                                                      uncommitted?: true)
  end

  it "lists every registry's entries, in order" do
    expect(registries.entries.map(&:path)).to eq(%w[/w /c])
  end

  it "asks about a path the registry that listed it" do
    registries.entries

    expect([registries.remove("/c"), registries.remove("/w"), registries.uncommitted?("/c")])
      .to eq([:clone_removed, :worktree_removed, true])
  end

  it "asks the first registry about a path none listed" do
    expect(registries.remove("/elsewhere")).to eq(:worktree_removed)
  end
end
