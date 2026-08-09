# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "mixlib/shellout"

# A throwaway git repo with two branches -- `trunk` and `feature` -- built ONCE
# per process and copied per example (`spec/lain/review/delta_spec.rb:8-30`'s
# shape, `spec/support/seed_repo.rb`'s reason). Named `trunk` rather than
# `main`: this box's `init.defaultBranch` already IS `main`, so a `checkout -b
# main` after {SeedRepo.at} collides with the branch `git init` just made.
# `feature` carries two commits over `trunk`, editing three well-separated
# lines of one 40-line file, so the cumulative diff has three hunks and every
# rewrite below has real content to preserve or break.
module HistoryRewriteRepo
  # {Isolation::Worktree}'s scrub, reused rather than duplicated -- an ambient
  # GIT_DIR (a pre-commit hook sets one) would otherwise point every call below
  # at the hook's own repository instead of the fixture.
  SCRUB = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB

  LINES = 40

  # Ten lines apart, comfortably outside `DIFF_HYGIENE`'s `-U3` context window
  # (7 lines: 3 before, the edit, 3 after), so each edit is its OWN hunk and
  # none of the three ever merges with another.
  TEN = 10
  TWENTY = 20
  THIRTY_FIVE = 35

  class << self
    # @param path [String] an existing empty directory to become the repository
    def copy_to(path)
      FileUtils.cp_r("#{template}/.", path)
      path
    end

    # @param changes [Hash{Integer=>String}] line number => replacement
    def content(changes = {})
      (1..LINES).map { |n| "#{changes.fetch(n, "line #{n}")}\n" }.join
    end

    private

    # Process-wide, and safe without a lock for the reason the whole suite is:
    # `parallel_tests` forks PROCESSES and one example runs at a time in each.
    def template = @template ||= build # rubocop:disable ThreadSafety/ClassInstanceVariable

    def build
      dir = Dir.mktmpdir("lain-history-template")
      at_exit { FileUtils.remove_entry(dir, true) }
      FileUtils.cp_r("#{SeedRepo.at("big.rb" => content)}/.", dir)
      branch(dir)
      dir
    end

    # `trunk`, not `main` -- see the module doc for why "checkout -b" of git's
    # own default name would collide.
    def branch(dir)
      git(dir, "checkout", "-q", "-b", "trunk")
      git(dir, "checkout", "-q", "-b", "feature")
      commit(dir, "feat: ten", { "big.rb" => content(TEN => "TEN") }, date: date_for(1))
      commit(dir, "feat: twenty and thirty-five",
             { "big.rb" => content(TEN => "TEN", TWENTY => "TWENTY", THIRTY_FIVE => "THIRTY-FIVE") },
             date: date_for(2))
      git(dir, "checkout", "-q", "trunk")
    end

    def commit(dir, message, files, date:)
      files.each { |path, body| File.write(File.join(dir, path), body) }
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", message, date:)
    end

    # A fixed, deterministic clock. Commit dates must be pinned or shas vary
    # per run and a base-unchanged (or hunk-unchanged) assertion built by
    # comparing two independently-resolved changesets becomes noise -- a first
    # spike attempt made exactly that mistake and reported four false
    # positives (chunk-survey-corpus.md's grounding).
    def date_for(offset) = Time.at(1_700_000_000 + offset).utc.iso8601

    def git(dir, *, date: nil)
      env = date ? SCRUB.merge("GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date) : SCRUB
      Mixlib::ShellOut.new("git", "-C", dir, *, environment: env).run_command.error!
    end
  end
end

# Pins that history rewriting preserves marks -- a CHARACTERIZATION of
# behaviour that already works and that nothing else tests at the seam level.
# `session_spec.rb` pins the digest FUNCTION against a fabricated source
# double; nothing pins the property against real git, so a change that swaps
# `LocalBranch#diff` for a walk-derived diff, or drops `-U3` from
# `DIFF_HYGIENE`, would leave every existing spec green while destroying it.
#
# Every assertion is made at the {Lain::Review::Changeset} level -- files,
# hunk keys, digest -- and not only at {Lain::Review::Source::LocalBranch}'s,
# so a later change to what {Lain::Review::Changeset} READS (rather than what
# `LocalBranch` PRODUCES) cannot break this property while this spec stays
# green.
RSpec.describe "history rewriting preserves marks", :seam do
  around do |example|
    Dir.mktmpdir("lain-history-repo") do |repo|
      @repo = HistoryRewriteRepo.copy_to(File.realpath(repo))
      example.run
    end
  end

  before { @clock = 1_700_100_000 }

  # A separate, later clock from the template's -- collision would be
  # harmless (git tolerates two commits sharing a date), but a distinct range
  # keeps a stray timestamp legible as "template" or "rewrite" while
  # debugging.
  def next_date
    @clock += 1
    Time.at(@clock).utc.iso8601
  end

  def repo_git(*args, date: nil)
    env = if date
            HistoryRewriteRepo::SCRUB.merge("GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date)
          else
            HistoryRewriteRepo::SCRUB
          end
    shell = Mixlib::ShellOut.new("git", "-C", @repo, *args, environment: env)
    shell.run_command
    shell.error!
    shell
  end

  def repo_commit(message, files, date: next_date)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    repo_git("add", "-A")
    repo_git("commit", "-q", "-m", message, date:)
  end

  def sha(rev) = repo_git("rev-parse", "--verify", rev).stdout.strip

  def changeset_for(base:, head:)
    source = Lain::Review::Source::LocalBranch.new(base:, head:, repo_root: @repo)
    Lain::Review::Changeset.new(source:)
  end

  # Every hunk key the changeset produces, by the SAME batch rule
  # {Lain::Review::Marks} applies -- derived independently of the session
  # under test, so this helper cannot catch the subject keying things
  # differently from itself.
  def all_keys(changeset) = Lain::Review::Session::MarkedChangeset.keys_by_path(changeset).values.flatten

  # Opens a round and marks every hunk reviewed, returning the session and the
  # journal lines a resume would read.
  def review_all(changeset)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    session = Lain::Review::Session.open(changeset:, journal:, source: "history_rewrite_spec",
                                         surface: Lain::Review::Surface::Null.new)
    all_keys(changeset).each { |key| session.mark(key, Lain::Review::Marks::REVIEWED) }
    [session, io.string.lines]
  end

  def resume(entries, changeset)
    Lain::Review::Session.from_journal(entries, changeset:, journal: Lain::Journal.new(io: StringIO.new),
                                                surface: Lain::Review::Surface::Null.new)
  end

  # Every mark reviewed, and nothing pruned -- the shape "survives
  # reconciliation" takes in every scenario below that expects survival.
  def expect_every_mark_to_survive(entries, changeset, original_keys)
    resumed = resume(entries, changeset)

    expect(resumed.marks.to_h.keys).to match_array(original_keys)
    expect(resumed.marks.states(changeset).values).to all(eq(:reviewed))
  end

  describe "rewrites that keep the base and the final tree" do
    it "reordering the commits leaves every mark standing" do
      before_changeset = changeset_for(base: "trunk", head: "feature")
      _, entries = review_all(before_changeset)
      original_keys = all_keys(before_changeset)
      ten = sha("feature~1")
      rest = sha("feature")

      repo_git("checkout", "-q", "-b", "reordered", "trunk")
      repo_git("cherry-pick", rest, date: next_date)
      repo_git("cherry-pick", ten, date: next_date)

      after_changeset = changeset_for(base: "trunk", head: "reordered")
      expect(after_changeset.base_ref).to eq(before_changeset.base_ref)
      expect(Lain::Review::Session.digest(after_changeset)).to eq(Lain::Review::Session.digest(before_changeset))
      expect_every_mark_to_survive(entries, after_changeset, original_keys)
    end

    it "squashing the commits into one leaves every mark standing" do
      before_changeset = changeset_for(base: "trunk", head: "feature")
      _, entries = review_all(before_changeset)
      original_keys = all_keys(before_changeset)

      repo_git("checkout", "-q", "-b", "squashed", "trunk")
      repo_git("merge", "--squash", "-q", "feature")
      repo_git("commit", "-q", "-m", "squash", date: next_date)

      after_changeset = changeset_for(base: "trunk", head: "squashed")
      expect(after_changeset.base_ref).to eq(before_changeset.base_ref)
      expect(Lain::Review::Session.digest(after_changeset)).to eq(Lain::Review::Session.digest(before_changeset))
      expect_every_mark_to_survive(entries, after_changeset, original_keys)
    end

    it "splitting one commit in two leaves every mark standing" do
      before_changeset = changeset_for(base: "trunk", head: "feature")
      _, entries = review_all(before_changeset)
      original_keys = all_keys(before_changeset)

      # A branch holding only "feat: ten", then the second commit's net
      # change rebuilt as two -- twenty alone, then twenty-and-thirty-five --
      # so the final tree still matches `feature`'s exactly.
      repo_git("checkout", "-q", "-b", "split", "feature~1")
      repo_commit("feat: twenty",
                  { "big.rb" => HistoryRewriteRepo.content(HistoryRewriteRepo::TEN => "TEN",
                                                           HistoryRewriteRepo::TWENTY => "TWENTY") })
      repo_commit("feat: thirty-five",
                  { "big.rb" => HistoryRewriteRepo.content(HistoryRewriteRepo::TEN => "TEN",
                                                           HistoryRewriteRepo::TWENTY => "TWENTY",
                                                           HistoryRewriteRepo::THIRTY_FIVE => "THIRTY-FIVE") })

      after_changeset = changeset_for(base: "trunk", head: "split")
      expect(after_changeset.base_ref).to eq(before_changeset.base_ref)
      expect(Lain::Review::Session.digest(after_changeset)).to eq(Lain::Review::Session.digest(before_changeset))
      expect_every_mark_to_survive(entries, after_changeset, original_keys)
    end

    it "rewording a commit message leaves every mark standing" do
      before_changeset = changeset_for(base: "trunk", head: "feature")
      _, entries = review_all(before_changeset)
      original_keys = all_keys(before_changeset)
      ten = sha("feature~1")
      rest = sha("feature")

      repo_git("checkout", "-q", "-b", "reworded", "trunk")
      repo_git("cherry-pick", ten, date: next_date)
      repo_git("commit", "--amend", "-q", "-m", "reworded: touch ten", date: next_date)
      repo_git("cherry-pick", rest, date: next_date)

      after_changeset = changeset_for(base: "trunk", head: "reworded")
      expect(after_changeset.base_ref).to eq(before_changeset.base_ref)
      expect(Lain::Review::Session.digest(after_changeset)).to eq(Lain::Review::Session.digest(before_changeset))
      expect_every_mark_to_survive(entries, after_changeset, original_keys)
    end

    it "main advancing without a rebase changes nothing" do
      before_changeset = changeset_for(base: "trunk", head: "feature")
      _, entries = review_all(before_changeset)
      original_keys = all_keys(before_changeset)

      repo_git("checkout", "-q", "trunk")
      repo_commit("chore: unrelated work", { "README.md" => "unrelated work\n" })

      after_changeset = changeset_for(base: "trunk", head: "feature")
      expect(after_changeset.base_ref).to eq(before_changeset.base_ref)
      expect_every_mark_to_survive(entries, after_changeset, original_keys)
    end
  end

  describe "rewrites that move the base" do
    it "a rebase discards every mark, whatever the hunk keys say" do
      before_changeset = changeset_for(base: "trunk", head: "feature")
      _, entries = review_all(before_changeset)

      # Far from every reviewed line (they run 10-35; this is a whole other
      # file), so the hunk bytes below have nothing to change.
      repo_git("checkout", "-q", "trunk")
      repo_commit("chore: unrelated work far away", { "far_away.rb" => "far away\n" })
      repo_git("checkout", "-q", "-b", "rebased", "feature")
      repo_git("rebase", "-q", "trunk", date: next_date)

      after_changeset = changeset_for(base: "trunk", head: "rebased")
      expect(after_changeset.base_ref).not_to eq(before_changeset.base_ref)
      expect(after_changeset.hunks.map(&:content_key)).to eq(before_changeset.hunks.map(&:content_key))
      expect { resume(entries, after_changeset) }.to raise_error(Lain::Review::Marks::BaseMismatch)
    end

    # A single-hunk branch (just "feat: ten"), so the one hunk under test is
    # unambiguous.
    it "a neighbour editing inside the context window rewrites the key" do
      repo_git("checkout", "-q", "-b", "only-ten", "feature~1")
      before_changeset = changeset_for(base: "trunk", head: "only-ten")
      before_hunk = before_changeset.hunks.first

      # Line 8 sits inside `-U3`'s context window around line 10 (3 lines
      # either side); an edit there rewrites the hunk's body without moving
      # the reviewer's own line 10 at all -- the count of lines is unchanged,
      # so nothing shifts position.
      repo_git("checkout", "-q", "trunk")
      repo_commit("chore: edit line eight", { "big.rb" => HistoryRewriteRepo.content(8 => "EIGHT") })
      repo_git("checkout", "-q", "-b", "rebased-ten", "only-ten")
      repo_git("rebase", "-q", "trunk", date: next_date)

      after_changeset = changeset_for(base: "trunk", head: "rebased-ten")
      after_hunk = after_changeset.hunks.first

      expect(after_hunk.old_start).to eq(before_hunk.old_start)
      expect(after_hunk.content_key).not_to eq(before_hunk.content_key)
    end

    it "renaming a file discards its marks" do
      repo_git("checkout", "-q", "-b", "only-ten", "feature~1")
      before_changeset = changeset_for(base: "trunk", head: "only-ten")
      _, entries = review_all(before_changeset)

      repo_git("checkout", "-q", "-b", "renamed", "only-ten")
      repo_git("mv", "big.rb", "renamed.rb")
      File.write(File.join(@repo, "renamed.rb"), HistoryRewriteRepo.content(HistoryRewriteRepo::TEN => "TEN-EDITED"))
      repo_git("add", "-A")
      repo_git("commit", "-q", "-m", "chore: rename and edit", date: next_date)

      after_changeset = changeset_for(base: "trunk", head: "renamed")
      expect(after_changeset.base_ref).to eq(before_changeset.base_ref)

      resumed = resume(entries, after_changeset)
      expect(resumed.marks.to_h).to be_empty
    end

    # The scenario above renames AND edits, so "no mark survives" holds for
    # two independent reasons at once -- content changed (a different
    # content_key on its own) and path changed (ditto) -- and cannot tell
    # which one did it. This is the isolating control: a PURE rename, no
    # write at all after `git mv`, compared against the SAME base as
    # `only-ten` so the cumulative diff still carries the original "feat:
    # ten" hunk. Verified empirically first (not assumed): a pure rename does
    # NOT collapse to zero hunks here, because the base predates the content
    # edit -- `after_hunk.lines`/`old_start`/`new_start` below are asserted
    # equal to prove the body and position are byte-for-byte the SAME hunk,
    # so `path` is the only variable left standing when the key changes and
    # the mark is dropped.
    it "a pure rename with no edit at all still discards its mark, on the path alone" do
      repo_git("checkout", "-q", "-b", "only-ten", "feature~1")
      before_changeset = changeset_for(base: "trunk", head: "only-ten")
      _, entries = review_all(before_changeset)
      before_hunk = before_changeset.hunks.first

      repo_git("checkout", "-q", "-b", "renamed-pure", "only-ten")
      repo_git("mv", "big.rb", "renamed.rb")
      repo_git("commit", "-q", "-m", "chore: pure rename, no edit", date: next_date)

      after_changeset = changeset_for(base: "trunk", head: "renamed-pure")
      after_hunk = after_changeset.hunks.first

      # The isolating control: body and position are unchanged, so path is
      # the only thing left that could have moved the key.
      expect(after_hunk.lines).to eq(before_hunk.lines)
      expect(after_hunk.old_start).to eq(before_hunk.old_start)
      expect(after_hunk.new_start).to eq(before_hunk.new_start)
      expect(after_hunk.content_key).not_to eq(before_hunk.content_key)

      expect(after_changeset.base_ref).to eq(before_changeset.base_ref)
      resumed = resume(entries, after_changeset)
      expect(resumed.marks.to_h).to be_empty
    end
  end
end
