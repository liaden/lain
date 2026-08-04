# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"

# Operates on a THROWAWAY repo it creates itself, never the lain repo it runs in
# -- the `spec/lain/isolation/` pattern, including {SeedRepo} for the initial
# commit and the subject's own env scrub for the spec's own git calls.
#
# The fixture is the shape the merge-base scenario needs and nothing more: a base
# branch and a feature branch that have BOTH moved since they forked. Under a
# two-dot diff the base's independent commit shows up as a spurious deletion,
# which is the mistake the spike found shifts every old-side anchor.
#
# Branches are created by explicit name rather than relying on whatever
# `init.defaultBranch` the box is configured with.
RSpec.describe Lain::Review::Source::LocalBranch, :seam do
  subject(:source) { described_class.new(base: "base", repo_root: @repo) }

  around do |example|
    Dir.mktmpdir("lain-review-repo") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at("shared.rb" => "a\nb\nc\n", "long.rb" => long_file)}/.", @repo)
      example.run
    end
  end

  # The spec's OWN git calls scrub the git-context env too, so building and
  # inspecting the throwaway repo is hermetic under an ambient GIT_*-polluted env
  # (a pre-commit hook) exactly as the subject is -- reusing the subject's pinned
  # scrub set rather than a parallel copy.
  #
  # The `-c` pins are the CONFIG half of that hermeticity, and they matter for a
  # different reason than the subject's: this side runs `commit`, so a developer
  # with `commit.gpgsign = true` would get a hanging or failing spec on a green
  # tree, and `core.hooksPath` would run their hooks inside the fixture.
  # No `-c` pins here: the repo is a copy of {SeedRepo}'s template, so it already
  # carries `commit.gpgsign=false` and `core.hooksPath=/dev/null` in its own
  # `.git/config`. One mechanism, in the place that covers every consumer.
  def run_git(*args, env: {})
    shell = Mixlib::ShellOut.new("git", "-C", @repo, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB.merge(env))
    shell.run_command.error!
    shell.stdout
  end

  # No keyword parameter here on purpose: `commit("m", "p" => "body")` passes a
  # brace-less hash, and declaring any keyword would make Ruby parse it as
  # keywords instead of as the positional Hash.
  def commit(message, files)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    run_git("add", "-A")
    run_git("commit", "-q", "-m", message)
    head
  end

  def head = run_git("rev-parse", "HEAD").strip

  # Long enough that a context window of 3 and one of 7 produce different hunk
  # headers, and seeded at the MERGE BASE so the diff is a modification rather
  # than a whole-file addition.
  def long_file(changed: false)
    (1..40).map { |n| n == 20 && changed ? "CHANGED\n" : "line #{n}\n" }.join
  end

  # base and feature both advance after the fork; @fork_point is the merge base.
  def diverge
    @fork_point = head
    run_git("checkout", "-q", "-b", "base")
    run_git("checkout", "-q", "-b", "feature")
    @first = commit("feature one\n\nwith a body paragraph.", "shared.rb" => "a\nCHANGED\nc\n")
    @second = commit("feature two", "added.rb" => "new file\n")

    run_git("checkout", "-q", "base")
    @base_only = commit("base advances independently", "base_only.rb" => "base\n")
    run_git("checkout", "-q", "feature")
  end

  # Extra feature commits, kept OUT of `diverge` so the targeted per-commit
  # assertions stay exact. The port contract needs a changeset that actually
  # contains each of these shapes, so its factory adds them all -- a mutation
  # that survives because the fixture cannot reach it is a missing fixture, not
  # an inert mutation.
  def add_binary
    File.binwrite(File.join(@repo, "blob.bin"), "\x00\x01\x02\xff".b)
    run_git("add", "-A")
    run_git("commit", "-q", "-m", "add a binary")
  end

  # A merge that carries content of its OWN -- a hand-resolved file that exists
  # in neither parent. `git log --numstat` reports nothing for a merge by
  # default, so this file is the one that goes missing.
  def add_merge
    run_git("checkout", "-q", "-b", "side", "base")
    @side_only = commit("side one", "side_only.rb" => "side\n")
    run_git("checkout", "-q", "feature")
    run_git("merge", "-q", "--no-ff", "--no-commit", "side")
    @merge = commit("merge side into feature", "only_in_merge.rb" => "resolved by hand\n")
  end

  def add_unicode = commit("a unicode path", "café.rb" => "unicode\n")

  # Explicit braces at the call site: this one takes a keyword, so a brace-less
  # hash would be parsed as keywords (see `commit`).
  def commit_at(message, files, stamp)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    run_git("add", "-A")
    run_git("commit", "-q", "-m", message,
            env: { "GIT_COMMITTER_DATE" => stamp, "GIT_AUTHOR_DATE" => stamp })
    head
  end

  # A child COMMITTED long before its parent. `git log`'s default is DATE order,
  # so under a bare `--reverse` this walks ahead of its own parent.
  def add_backdated_child
    stamp = "2001-01-01T00:00:00"
    run_git("commit", "-q", "--allow-empty", "-m", "back-dated child",
            env: { "GIT_COMMITTER_DATE" => stamp, "GIT_AUTHOR_DATE" => stamp })
    head
  end

  # A subject whose bytes are latin-1 rather than UTF-8. This is what exposes the
  # encoding defect: mixlib tags stdout UTF-8 when the bytes HAPPEN to be valid
  # and BINARY when they are not, so a field's encoding depends on its content.
  # An all-ASCII fixture cannot see it.
  def add_latin1_subject
    run_git("commit", "-q", "--allow-empty", "-m", "caf\xE9 subject".b)
    head
  end

  # A commit that DECLARES its encoding, which is what `i18n.commitEncoding`
  # writes into the commit object's `encoding` header. The setting is left in
  # place afterwards, because that is the realistic repo -- one configured for
  # latin-1 commits stays configured that way, and it is `i18n.logOutputEncoding`
  # falling back to it that makes `git log` emit raw latin-1 unless an output
  # encoding is asked for explicitly. Unsetting it would let git default to UTF-8
  # and the example would pass with or without the fix.
  # The message file lives under .git/ so `add -A` never picks it up.
  def add_declared_latin1_subject
    message = File.join(@repo, ".git", "latin1-msg.txt")
    File.binwrite(message, "caf\xE9 declared subject\n".b)
    run_git("config", "i18n.commitEncoding", "latin1")
    run_git("commit", "-q", "--allow-empty", "-F", message)
    head
  end

  # A mode-only change: git reports 0/0 for it, which is the same ambiguity the
  # binary fix removed. Pinned rather than fixed -- see the spec below.
  def add_mode_only
    File.write(File.join(@repo, "mode.sh"), "#!/bin/sh\n")
    run_git("add", "-A")
    run_git("commit", "-q", "-m", "add a script")
    run_git("update-index", "--chmod=+x", "mode.sh")
    run_git("commit", "-q", "-m", "chmod only")
  end

  before { diverge }

  describe "the merge base" do
    it "reports the merge base sha as base_ref, not the named base's tip" do
      expect(source.base_ref).to eq(@fork_point)
      expect(source.base_ref).not_to eq(@base_only)
    end

    it "excludes the base branch's independent commits from the diff" do
      expect(source.diff).to include("shared.rb", "added.rb")
      expect(source.diff).not_to include("base_only.rb")
    end

    it "resolves head_ref to the feature tip" do
      expect(source.head_ref).to eq(@second)
    end

    # The three-dot form is what makes the two agree. Pinning the RESOLVED shas
    # is the card's point: a source that recorded "base" symbolically would
    # answer a different diff once the base branch moved again.
    # The oracle is spelled with the subject's OWN pins rather than a bare
    # `git diff`, because otherwise this example disagrees merely because the
    # developer set `diff.noprefix` -- a difference in the spec's git, not in the
    # subject's answer. What it is here to prove is the merge-base resolution and
    # the two-dot equivalence; the flags have their own examples below.
    it "answers the same diff as an explicit merge-base..head two-dot diff" do
      oracle = run_git(*described_class::CONFIG_PINS, "diff",
                       *described_class::DIFF_HYGIENE, @fork_point, @second)
      expect(source.diff).to eq(oracle.b)
    end
  end

  describe "#commits" do
    it "returns them oldest-first" do
      expect(source.commits.map(&:sha)).to eq([@first, @second])
    end

    it "reports each commit's subject without its body" do
      expect(source.commits.map(&:subject)).to eq(["feature one", "feature two"])
    end

    it "reports the body separately, empty when the commit has none" do
      expect(source.commits.map(&:body)).to eq(["with a body paragraph.", ""])
    end

    it "gives each commit its OWN numstat, not the cumulative one" do
      expect(source.commits.map { |commit| commit.numstat.map(&:path) })
        .to eq([["shared.rb"], ["added.rb"]])
    end

    it "counts added and deleted lines per file" do
      shared = source.commits.first.numstat.first
      expect([shared.added, shared.deleted]).to eq([1, 1])
    end

    it "excludes the merge base commit itself" do
      expect(source.commits.map(&:sha)).not_to include(@fork_point)
    end

    it "excludes the base branch's independent commit" do
      expect(source.commits.map(&:sha)).not_to include(@base_only)
    end
  end

  describe "a binary file in the walk" do
    before { add_binary }

    it "reports no line counts rather than zeroes, which would read as an empty text change" do
      entry = source.commits.last.numstat.first
      expect(entry).to be_binary
      expect([entry.added, entry.deleted]).to eq([nil, nil])
    end
  end

  # A file changed only by a hand resolution inside a merge is in the diff and,
  # by default, in no commit's numstat at all -- the walk silently loses it.
  describe "a merge commit in the walk" do
    before { add_merge }

    it "attributes the merge's own resolved file to the merge commit" do
      merge = source.commits.find { |commit| commit.sha == @merge }
      expect(merge.numstat.map(&:path)).to include("only_in_merge.rb")
    end

    it "leaves no file in the diff unaccounted for by the walk" do
      walked = source.commits.flat_map { |commit| commit.numstat.map(&:path) }.to_set
      expect(walked).to include("only_in_merge.rb", "side_only.rb", "shared.rb", "added.rb")
    end

    it "still ends the walk at the head" do
      expect(source.commits.last.sha).to eq(source.head_ref)
    end
  end

  # Ancestry, not timestamps. Rebases, cherry-picks and a wrong system clock all
  # produce a commit whose date precedes its parent's, and ordering the review by
  # date would then show a change before the change it depends on.
  describe "a commit dated before its parent" do
    it "walks after its parent anyway" do
      child = add_backdated_child
      shas = source.commits.map(&:sha)
      expect(shas.index(child)).to be > shas.index(@second)
    end

    it "is still the head, being the newest by ancestry" do
      child = add_backdated_child
      expect(source.commits.last.sha).to eq(child)
    end
  end

  # The walk IS the reading order. Ordering it by date interleaves two branches,
  # so a reviewer reads a feature commit, jumps into the side branch, and comes
  # back. Topological order keeps each branch contiguous.
  describe "a side branch whose dates interleave with the feature's" do
    before do
      run_git("checkout", "-q", "-b", "interleaved", "base")
      commit_at("side early", { "side_early.rb" => "s\n" }, "2020-03-01T00:00:00")
      run_git("checkout", "-q", "feature")
      commit_at("feature late", { "feature_late.rb" => "f\n" }, "2020-06-01T00:00:00")
      run_git("merge", "-q", "--no-ff", "-m", "merge interleaved", "interleaved")
    end

    it "keeps each branch contiguous instead of interleaving them by date" do
      subjects = source.commits.map(&:subject)
      expect(subjects.index("feature late")).to be < subjects.index("side early")
    end
  end

  # The rich fixture carries a binary file and a latin-1 subject, which makes the
  # diff bytes invalid UTF-8 -- and mixlib then tags them BINARY on its own. It
  # is the ALL-ASCII changeset that shows the forcing doing work, because there
  # mixlib hands back UTF-8.
  describe "an all-ASCII changeset" do
    it "still answers the diff as raw bytes" do
      expect(source.diff.encoding).to eq(Encoding::ASCII_8BIT)
    end
  end

  describe "text fields off the wire" do
    before do
      add_unicode
      add_latin1_subject
    end

    # Only #diff is deliberately binary; a subject or path inheriting mixlib's
    # content-dependent encoding breaks JSON generation into the NDJSON Journal,
    # which is the experiment record and where one bad line breaks the parse.
    it "reports sha, subject, body and path as UTF-8, not binary" do
      encodings = source.commits.flat_map do |commit|
        [commit.sha, commit.subject, commit.body, *commit.numstat.map(&:path)]
      end.map(&:encoding).uniq
      expect(encodings).to eq([Encoding::UTF_8])
    end

    # Transcoded, not mangled. Scrubbing a declared latin-1 subject would answer
    # "caf�" -- readable as damage rather than as the word the author wrote.
    # Scrub stays as the backstop for genuinely undeclared bytes.
    it "transcodes a subject whose commit declares a non-UTF-8 encoding" do
      add_declared_latin1_subject
      expect(source.commits.last.subject).to eq("café declared subject")
    end

    it "reports text fields whose bytes are valid in the encoding they claim" do
      fields = source.commits.flat_map { |commit| [commit.subject, commit.body] }
      expect(fields).to all(be_valid_encoding)
    end

    it "survives JSON generation, which is how a record reaches the Journal" do
      expect { source.commits.map { |commit| { subject: commit.subject }.to_json } }.not_to raise_error
    end

    # git QUOTES a non-ASCII path by default, so the same source answers a
    # different path depending on the developer's core.quotePath. That is not a
    # filename any caller can open.
    it "reports a non-ASCII path verbatim, whatever core.quotePath is set to" do
      run_git("config", "core.quotePath", "true")
      expect(source.commits.flat_map { |commit| commit.numstat.map(&:path) }).to include("café.rb")
    end
  end

  describe "determinism against the developer's git config" do
    # diff.noprefix rewrites the header to `diff --git a.rb a.rb`, and the
    # parser's own `a/`+`b/` regex stops matching.
    it "keeps the a/ and b/ prefixes when diff.noprefix is set" do
      run_git("config", "diff.noprefix", "true")
      expect(source.diff).to match(%r{^diff --git a/shared\.rb b/shared\.rb$})
    end

    # A 3-line file cannot show this: every context setting produces the same
    # hunk header. long.rb is seeded at the merge base for exactly this reason.
    it "keeps three lines of context when diff.context is set" do
      commit("change its middle", "long.rb" => long_file(changed: true))
      run_git("config", "diff.context", "7")
      expect(source.diff).to match(/^@@ -17,7 \+17,7 @@/)
    end
  end

  describe "an unresolvable ref" do
    it "refuses loudly, naming the base ref" do
      expect { described_class.new(base: "no-such-branch", repo_root: @repo) }
        .to raise_error(Lain::Review::Source::UnknownRef, /no-such-branch/)
    end

    it "refuses loudly, naming the head ref" do
      expect { described_class.new(base: "base", head: "no-such-head", repo_root: @repo) }
        .to raise_error(Lain::Review::Source::UnknownRef, /no-such-head/)
    end

    # Two roots have no merge base, so there is nothing to anchor the old side
    # to. Answering a diff against the empty tree would silently review the whole
    # branch as additions.
    it "refuses when the two refs share no history" do
      run_git("checkout", "-q", "--orphan", "unrelated")
      run_git("rm", "-rqf", ".")
      commit("unrelated root", "other.rb" => "x\n")
      expect { described_class.new(base: "base", head: "unrelated", repo_root: @repo) }
        .to raise_error(Lain::Review::Source::UnknownRef, /merge base/)
    end

    # Reporting only `head ref "HEAD" does not resolve` for a directory that is
    # not a repository throws away the one sentence that says what is wrong.
    it "names the repo_root and carries git's own words when the root is not a repository" do
      Dir.mktmpdir("not-a-repo") do |empty|
        expect { described_class.new(base: "base", repo_root: empty) }
          .to raise_error(Lain::Review::Source::UnknownRef, /#{Regexp.escape(empty)}.*not a git repository/m)
      end
    end

    it "names the repo_root when it does not exist at all" do
      expect { described_class.new(base: "base", repo_root: "/nonexistent/path") }
        .to raise_error(Lain::Review::Source::UnknownRef, %r{/nonexistent/path})
    end

    # Structural, rather than relying on rev-parse happening to reject an
    # unknown option: `--end-of-options` means a ref can never be read as a flag.
    it "treats a leading-dash ref as a ref, never as an option" do
      expect { described_class.new(base: "--upload-pack=touch /tmp/lain-canary", repo_root: @repo) }
        .to raise_error(Lain::Review::Source::UnknownRef, /upload-pack/)
      expect(File).not_to exist("/tmp/lain-canary")
    end
  end

  describe "the subprocess seam" do
    it "spells git as an argv array through the injected factory, so nothing reaches a shell" do
      calls = []
      factory = lambda { |*argv, **options|
        calls << argv
        Mixlib::ShellOut.new(*argv, **options)
      }
      described_class.new(base: "base", repo_root: @repo, shell_out_factory: factory).diff
      expect(calls).not_to be_empty
      expect(calls).to all(start_with("git"))
      expect(calls.flatten).not_to include("sh", "bash", "zsh", "-lc")
      # Every `-c` is git's OWN config flag carrying a key=value, never a shell's
      # "run this string". Asserting the shape beats banning the token, which is
      # what this spec used to do -- and which broke the moment the subject
      # legitimately needed `-c core.quotePath=false`.
      config_values = calls.flat_map { |argv| argv.each_cons(2).filter_map { |flag, value| value if flag == "-c" } }
      expect(config_values).to all(match(/\A[\w.]+=\S*\z/))
    end
  end

  # A KNOWN LIMIT, pinned so it is deliberate rather than discovered. git reports
  # a mode-only change as 0/0, which is the same ambiguity the binary fix removed
  # -- a caller cannot tell it from a text file nothing changed in. Fixing it
  # needs a `--raw` pass to read the mode bits, which is a second subprocess and
  # a field on FileStat; that is a design change, not a detail, so it is recorded
  # here and left to whoever needs it.
  describe "a mode-only change" do
    before { add_mode_only }

    it "reports 0/0 and is NOT distinguishable from an unchanged text file" do
      entry = source.commits.last.numstat.first
      expect(entry.path).to eq("mode.sh")
      expect([entry.added, entry.deleted, entry.binary?]).to eq([0, 0, false])
    end
  end

  # Also a deliberate answer rather than an accident: a branch already merged
  # into its base has nothing to review, and that is a state, not an error.
  # Refusing it would make "review a branch that is already merged" a failure.
  describe "a changeset with nothing in it" do
    it "answers an empty diff and an empty walk rather than refusing" do
      merged = described_class.new(base: "feature", head: "feature", repo_root: @repo)
      expect(merged.diff).to be_empty
      expect(merged.commits).to be_empty
      expect(merged.base_ref).to eq(merged.head_ref)
    end
  end

  # The port contract's fixture is the RICH one: a merge carrying its own file, a
  # binary, and a non-ASCII path. Each of those is a shape that made some
  # assertion in the group vacuous while it was absent.
  it_behaves_like "a review changeset source", source: lambda {
    add_binary
    add_unicode
    add_latin1_subject
    add_merge
    described_class.new(base: "base", repo_root: @repo)
  }
end
