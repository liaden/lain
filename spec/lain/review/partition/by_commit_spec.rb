# frozen_string_literal: true

# The conservation rules this strategy inherited from `Changeset#by_commit`,
# moved here with the code that enforces them: one group per commit in walk
# order, an overlapping file under the LAST commit that touched it, and a loud
# refusal for a file no numstat accounts for. They are behaviour to preserve,
# not to redesign, so the examples below are the ones `changeset_spec.rb` held
# before the grouping left `Changeset`.
#
# A real {Lain::Review::Changeset} over a synthetic diff, never a double:
# attribution joins the diff's paths to the walk's numstat paths, and a double
# would let the fixture answer a join the parser never produces.
RSpec.describe Lain::Review::Partition::ByCommit do
  subject(:strategy) { described_class.new }

  def commit_record(sha:, subject: "s", body: "", paths: [], added: 1, deleted: 1)
    numstat = paths.map { |path| Lain::Review::Source::FileStat.new(path: -path, added:, deleted:) }
    Lain::Review::Source::Commit.new(sha:, subject:, body:, numstat: numstat.freeze)
  end

  def changeset_over(diff, commits:)
    source = instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, commits: commits.freeze,
                                                                base_ref: "b" * 40, head_ref: "h" * 40)
    Lain::Review::Changeset.new(source:)
  end

  def diff_over(paths)
    paths.map do |path|
      "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-a\n+b\n"
    end.join
  end

  # `shared.rb` is touched by BOTH commits. The cumulative diff shows its hunks
  # once, so a grouping that hands them to every commit that touched the file
  # double-counts and the sum stops meaning anything.
  let(:commits) do
    [commit_record(sha: "c1", subject: "first", paths: %w[shared.rb only_first.rb]),
     commit_record(sha: "c2", subject: "second", paths: %w[shared.rb only_second.rb])]
  end

  let(:diff) { diff_over(%w[only_first.rb shared.rb only_second.rb]) }
  let(:changeset) { changeset_over(diff, commits:) }

  it "answers the strategy port, so it can be handed anywhere one is taken" do
    expect { Lain::Review::Partition::Strategy.check!(strategy) }.not_to raise_error
  end

  it "names itself in the vocabulary's own spelling for the walk" do
    expect(strategy.name).to eq("commits")
  end

  it "advises presenting per commit, naming the scope that does it" do
    expect(strategy.advice).to include("commits")
  end

  # The one strategy that declines a source, and the reason `#supports?` is on
  # the port at all: a source with no history cannot be grouped by one, and
  # saying so at presentation beats dying on a missing message mid-partition.
  describe "#supports?" do
    it "supports a source that answers a commit walk" do
      expect(strategy.supports?(instance_double(Lain::Review::Source::LocalBranch, commits: []))).to be(true)
    end

    it "declines a source with no commit history to group by" do
      expect(strategy.supports?(Object.new)).to be(false)
    end
  end

  describe "the grouping" do
    it "yields one partition per commit, in walk order, labelled by its subject" do
      expect(strategy.partition(changeset).map(&:label)).to eq(%w[first second])
    end

    it "partitions the files, so the groups' hunks sum to the cumulative hunk count" do
      expect(strategy.partition(changeset).sum { |group| group.files.sum { |file| file.hunks.size } })
        .to eq(changeset.hunks.size)
    end

    it "gives an overlapping file to the LAST commit that touched it, never to both" do
      expect(strategy.partition(changeset).map { |group| group.files.map(&:path) })
        .to eq([["only_first.rb"], %w[shared.rb only_second.rb]])
    end

    it "partitions the same way twice, so a re-render cannot reorder the view" do
      expect(strategy.partition(changeset).map(&:label)).to eq(strategy.partition(changeset).map(&:label))
    end

    it "refuses loudly rather than drop a file no commit's numstat accounts for" do
      orphaned = changeset_over(diff, commits: [commit_record(sha: "c1", paths: ["shared.rb"])])

      expect { strategy.partition(orphaned) }
        .to raise_error(Lain::Review::Changeset::Unattributed, /only_first\.rb/)
    end

    # A commit whose every file was later superseded gets an EMPTY group rather
    # than disappearing from the walk -- skipping it is the silent drop the
    # whole axis exists to refuse.
    it "keeps a commit whose files were all superseded, with no files under it" do
      superseded = [commit_record(sha: "c1", subject: "first", paths: %w[shared.rb]),
                    commit_record(sha: "c2", subject: "second", paths: %w[shared.rb only_first.rb only_second.rb])]

      expect(strategy.partition(changeset_over(diff, commits: superseded)).map { |group| group.files.size })
        .to eq([0, 3])
    end

    it "answers partitions that withhold #hunks, so no group reaches Marks#reconcile" do
      expect(strategy.partition(changeset)).to all(satisfy { |group| !group.respond_to?(:hunks) })
    end

    it "answers frozen, shareable groups, so no reachable mutable state remains" do
      expect(strategy.partition(changeset)).to all(satisfy { |group| Ractor.shareable?(group) })
    end
  end

  # A commit knows what IT changed, which is not its share of the cumulative
  # diff -- so this strategy supplies a detail rather than letting the hunks be
  # counted. The numbers are git's own, and for a merge under
  # `--diff-merges=first-parent` that is the entire side branch.
  describe "the detail a commit partition carries" do
    subject(:detail) { strategy.partition(changeset).first.detail }

    it "carries the commit's identity, which the label alone cannot spell twice over" do
      expect([detail.sha, detail.subject, detail.body]).to eq(["c1", "first", ""])
    end

    it "carries the commit's OWN numstat, not the partition's share of the diff" do
      expect(detail.numstat.map(&:path)).to eq(%w[shared.rb only_first.rb])
    end

    it "sums that numstat rather than counting the group's hunks" do
      expect([detail.added([]), detail.deleted([])]).to eq([2, 2])
    end

    # What a refusal names the group by, which is NOT what a heading renders:
    # a sidebar has 40 columns and wants the message, while a reader told their
    # review is too large needs something they can `git show`. Subjects repeat
    # (`wip`, `fixup!`, `Merge branch 'main'`), so the label alone cannot be
    # looked up, and it does not say what KIND of thing it names.
    it "names a group by its subject AND the commit it can be looked up by" do
      expect(detail.named("first")).to eq("first (commit c1)")
    end

    it "abbreviates a real sha rather than spending 40 columns on it" do
      long = described_class::Commit.new(sha: "a" * 40, subject: "s", body: "", numstat: [])

      expect(long.named("s")).to eq("s (commit aaaaaaaaaaaa)")
    end

    # `git commit --allow-empty-message` is legal, and the label is then "".
    # Interpolating it leaves the refusal opening on a bare space.
    it "still names an empty-message commit, rather than opening a refusal with a space" do
      empty = described_class::Commit.new(sha: "b" * 40, subject: "", body: "", numstat: [])

      expect(empty.named("")).to eq("commit bbbbbbbbbbbb")
    end

    # git spells a binary file's stats `-`, not 0, precisely because 0/0 is a
    # claim about lines nobody can make.
    it "counts the binary files its line sums had to skip" do
      binaries = [commit_record(sha: "c1", paths: %w[shared.rb only_first.rb only_second.rb],
                                added: nil, deleted: nil)]
      group = strategy.partition(changeset_over(diff, commits: binaries)).first

      expect([group.detail.added([]), group.detail.binaries([])]).to eq([0, 3])
    end
  end
end
