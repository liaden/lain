# frozen_string_literal: true

RSpec.describe Lain::Isolation::MergeStrategy do
  subject(:strategy) { described_class::DEFAULT }

  # `git merge` has no `--conflict` flag, so the style rides in as a `-c`
  # override, which beats any config file the repository or the user carries.
  # The four behaviour flags undo what `merge.ff`, `branch.<b>.mergeOptions` and
  # `merge.verifySignatures` would otherwise do to a handback.
  # rerere is pinned off too: a user's `rerere.autoupdate` replays and stages
  # an old resolution, so a real conflict comes back with no unmerged paths
  # and reads as a failure instead.
  it "puts the conflict style, rerere, the diff algorithm and the merge's behaviour on git's own command line" do
    expect(strategy.merge("refs/lain/worker/w"))
      .to eq(["-c", "merge.conflictStyle=zdiff3", "-c", "rerere.enabled=false", "merge", "--ff", "--no-squash",
              "--commit", "--no-verify-signatures", "--no-edit", "-X", "diff-algorithm=histogram",
              "refs/lain/worker/w"])
  end

  it "spells a rebase the same way, for a worker syncing itself onto the tip" do
    expect(strategy.rebase("a" * 40))
      .to eq(["-c", "merge.conflictStyle=zdiff3", "-c", "rerere.enabled=false", "rebase",
              "-X", "diff-algorithm=histogram", "a" * 40])
  end

  it "is built from the [isolation] table" do
    isolation = Lain::Config::Isolation.from({ "conflict_style" => "diff3", "diff_algorithm" => "patience" },
                                             path: "config.toml")

    expect(described_class.from(isolation).merge("r"))
      .to include("merge.conflictStyle=diff3", "diff-algorithm=patience")
  end

  it "defaults to the ruled strategy, the same one an absent table yields" do
    expect(described_class.from(Lain::Config::Isolation.empty)).to eq(strategy)
  end

  it "names itself in the words the handback record journals" do
    expect(strategy.to_s).to eq("conflict_style=zdiff3 diff_algorithm=histogram")
  end

  it "refuses a style git does not know, naming it" do
    expect { described_class.new(conflict_style: "zdiff4", diff_algorithm: "histogram") }
      .to raise_error(Lain::Config::Isolation::InvalidValue, /conflict_style = "zdiff4"/)
  end

  it "is deeply frozen" do
    expect(strategy).to be_deeply_frozen
  end
end
