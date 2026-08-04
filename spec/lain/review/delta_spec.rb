# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "mixlib/shellout"

# The whole re-review story -- three commits reviewed, a base that moved under
# them, a rebase, an amend and a rework -- built ONCE per process and copied per
# example.
#
# Every example needs those twenty-odd spawns before its own first assertion,
# and `source/local_branch_spec` is the suite's longest file for precisely that
# reason. So the history is built once and `cp_r`'d: ~200ms to build, ~4ms to
# copy. Safe to copy for {SeedRepo}'s own reason -- a `.git` with no worktrees
# in it holds no absolute path anywhere, so a copy IS the repo.
module ReviewDeltaRepo
  # The same scrub the subject uses, so building the template is hermetic under
  # an ambient GIT_*-polluted env (a pre-commit hook sets one) exactly as it is.
  # The CONFIG half arrives with the copy: {SeedRepo}'s template already carries
  # `commit.gpgsign=false` and `core.hooksPath=/dev/null` in its `.git/config`.
  SCRUB = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB

  # Forty lines, so amending ONE of them is a hunk rather than a rewrite.
  # `range-diff` pairs commits by patch similarity against a creation factor of
  # 60%, and the only line of a one-line file amended is a 100% rewrite -- it
  # comes back as a drop PLUS an add, never as a change. The spike's own fixture
  # did exactly that and so could not produce a `!` marker at all.
  LINES = 40

  # Refs, not instance variables: the shas have to survive `cp_r` into an
  # example's own repository, and a ref is the only thing that does.
  PINNED_HEAD = "refs/test/pinned/head"
  PINNED_BASE = "refs/test/pinned/base"

  # A stand-in for gpg, because signing for real needs a key this box may not
  # have. It answers git's `--status-fd` handshake on SIGN -- without the
  # SIG_CREATED line git refuses the commit outright -- and on VERIFY prints the
  # way gpg does. That verification line lands on git's STDOUT, in among
  # `--name-only`'s file names, which is the whole point of the example using it.
  # The `cat` is not decoration and cost a flake to find: git writes the payload
  # to be signed on this process's stdin, and a child that answers and exits
  # without draining it leaves git's write to lose a race it usually wins --
  # `error: gpg failed to sign the data`, roughly one run in twenty, and only on
  # a loaded box. Draining first makes the handshake ordered rather than lucky.
  FAKE_GPG = <<~SH
    #!/bin/sh
    cat > /dev/null
    for arg in "$@"; do
      case "$arg" in
        --verify) echo "gpg: a fake verification line" >&2; exit 0 ;;
      esac
    done
    echo "[GNUPG:] SIG_CREATED B 1 8 00 1700000000 fake" >&2
    printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nZmFrZQ==\\n-----END PGP SIGNATURE-----\\n'
    exit 0
  SH

  class << self
    # @param path [String] an existing empty directory to become the repository
    def copy_to(path)
      FileUtils.cp_r("#{template}/.", path)
      path
    end

    # @param changes [Hash{Integer=>String}] line number => replacement
    def big(changes = {})
      (1..LINES).map { |n| "#{changes.fetch(n, "line #{n}")}\n" }.join
    end

    private

    # Process-wide, and safe without a lock for the reason the whole suite is:
    # `parallel_tests` forks PROCESSES and one example runs at a time in each.
    def template = @template ||= build # rubocop:disable ThreadSafety/ClassInstanceVariable

    def build
      dir = Dir.mktmpdir("lain-delta-template")
      at_exit { FileUtils.remove_entry(dir, true) }
      FileUtils.cp_r("#{SeedRepo.at("big.rb" => big)}/.", dir)
      review(dir)
      move_base(dir)
      rewrite(dir)
      # Left on `base` so no example inherits a checkout of a branch it is
      # about to rewrite.
      git(dir, "checkout", "-q", "base")
      dir
    end

    # Branches by explicit name rather than whatever `init.defaultBranch` the
    # box is configured with.
    def review(dir)
      git(dir, "checkout", "-q", "-b", "base")
      git(dir, "update-ref", PINNED_BASE, "HEAD")
      git(dir, "checkout", "-q", "-b", "feature")
      commit(dir, "feat: one", "big.rb" => big(5 => "FIVE"))
      commit(dir, "feat: two", "u.rb" => "two\n")
      commit(dir, "feat: three", "big.rb" => big(5 => "FIVE", 30 => "THIRTY"))
      git(dir, "update-ref", PINNED_HEAD, "HEAD")
    end

    # Somebody else lands something on the base branch. Under a tree compare
    # this file is what the human is wrongly asked to re-read.
    def move_base(dir)
      git(dir, "checkout", "-q", "base")
      commit(dir, "chore: readme", "README.md" => "unrelated work\n")
    end

    def rewrite(dir)
      git(dir, "checkout", "-q", "-b", "rebased", "feature")
      git(dir, "rebase", "-q", "base")
      git(dir, "checkout", "-q", "-b", "amended", "rebased")
      amend(dir, "big.rb" => big(5 => "FIVE", 30 => "THIRTY-FIXED"))
      git(dir, "checkout", "-q", "-b", "reworked", "rebased~1")
      commit(dir, "feat: four", "v.rb" => "four\n")
      widen(dir)
      merge(dir)
      land(dir)
    end

    # The base branch with the REVIEWED commits merged into it -- the branch
    # landed while a re-review was still open. It is the one shape in which
    # `<reviewed base>..<reviewed head>` and `<base now>..<reviewed head>`
    # disagree: against this base the reviewed commits are already reachable, so
    # the second spelling answers an empty series and every entry vanishes.
    def land(dir)
      git(dir, "checkout", "-q", "-b", "landed", "base")
      git(dir, "merge", "-q", "--no-ff", "-m", "land feature", "feature")
    end

    # Thirteen entries against the pinned three, which is what makes git
    # right-align BOTH indices -- ` 1:` rather than `1:`. Under ten it never
    # pads, so a parser that cannot read the padded form looks correct.
    def widen(dir)
      git(dir, "checkout", "-q", "-b", "padded", "rebased")
      (1..10).each { |n| commit(dir, "pad #{n}", "pad#{n}.rb" => "#{n}\n") }
    end

    # A merge carrying content of its OWN -- a file in neither parent. This is
    # the shape that shows range-diff omitting merges: the hand-resolved file
    # belongs to no entry, so nothing downstream can name it.
    def merge(dir)
      git(dir, "checkout", "-q", "-b", "side", "base")
      commit(dir, "side one", "side_only.rb" => "side\n")
      git(dir, "checkout", "-q", "-b", "merged", "rebased")
      git(dir, "merge", "-q", "--no-ff", "--no-commit", "side")
      commit(dir, "merge side into feature", "only_in_merge.rb" => "resolved by hand\n")
    end

    def commit(dir, message, files)
      write(dir, files)
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", message)
    end

    def amend(dir, files)
      write(dir, files)
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "--amend", "--no-edit")
    end

    def write(dir, files) = files.each { |path, body| File.write(File.join(dir, path), body) }

    def git(dir, *)
      Mixlib::ShellOut.new("git", "-C", dir, *, environment: SCRUB).run_command.error!
    end
  end
end

# Drives real git in a throwaway repository, never the lain repo it runs in.
RSpec.describe Lain::Review::Delta, :seam do
  subject(:delta) { delta_for("amended") }

  around do |example|
    Dir.mktmpdir("lain-delta-repo") do |repo|
      @repo = ReviewDeltaRepo.copy_to(File.realpath(repo))
      example.run
    end
  end

  def delta_for(branch, base: "base")
    described_class.new(pinned_base: ReviewDeltaRepo::PINNED_BASE,
                        pinned_head: ReviewDeltaRepo::PINNED_HEAD,
                        base:, head: branch, repo_root: @repo)
  end

  # The spec's own git calls scrub the git-context env exactly as the subject
  # does. No `-c` pins here: the repo is a copy of {SeedRepo}'s template, so it
  # already carries `commit.gpgsign=false` and `core.hooksPath=/dev/null`.
  def run_git(*args)
    shell = Mixlib::ShellOut.new("git", "-C", @repo, *args, environment: ReviewDeltaRepo::SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def sha(rev) = run_git("rev-parse", "--verify", rev).strip

  def config(key, value) = run_git("config", key, value)

  def commit_on(branch, message, files)
    run_git("checkout", "-q", branch)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    run_git("add", "-A")
    run_git("commit", "-q", "-m", message)
  end

  describe "the delta between a reviewed range and the branch as it stands now" do
    it "reports every rebased commit identical, though none of the shas match" do
      rebased = delta_for("rebased")

      expect(rebased.identical.size).to eq(3)
      expect(rebased.changed).to be_empty
      # The anti-vacuity half: a delta of a range against ITSELF would also
      # report three identical, and would say nothing about range-diff at all.
      expect(rebased.map { |entry| entry.old_sha == entry.new_sha }).to all(be(false))
    end

    it "reports the amended commit changed and the ones before it identical" do
      expect(delta.changed.map(&:subject)).to eq(["feat: three"])
      expect(delta.identical.map(&:subject)).to eq(["feat: one", "feat: two"])
    end

    it "excludes the base branch's own movement from the files to re-read" do
      expect(delta.paths).to eq(["big.rb"])
      # The control: comparing the two HEADS -- the primitive the spike measured
      # as wrong for this job -- drags in a file the human never reviewed. Without
      # this the example cannot tell range-diff from `git diff`.
      expect(run_git("diff", "--name-only", sha(ReviewDeltaRepo::PINNED_HEAD), sha("amended")))
        .to include("README.md")
    end

    it "reports a dropped commit and an added one as themselves, not as a change" do
      reworked = delta_for("reworked")

      expect(reworked.dropped.map(&:subject)).to eq(["feat: three"])
      expect(reworked.added.map(&:subject)).to eq(["feat: four"])
      expect(reworked.changed).to be_empty
      expect(reworked.identical.map(&:subject)).to eq(["feat: one", "feat: two"])
    end

    it "leaves the vanished side of a dropped or added entry nil, never a placeholder" do
      reworked = delta_for("reworked")

      expect(reworked.dropped.first).to have_attributes(new_sha: nil, new_index: nil,
                                                        old_sha: sha("feature"), old_index: 3)
      expect(reworked.added.first).to have_attributes(old_sha: nil, old_index: nil,
                                                      new_sha: sha("reworked"), new_index: 3)
    end

    it "gathers the files of a dropped commit and an added one alike" do
      expect(delta_for("reworked").paths).to eq(["big.rb", "v.rb"])
    end

    it "asks the human to re-read nothing when the branch has not been rewritten" do
      unchanged = delta_for("feature", base: ReviewDeltaRepo::PINNED_BASE)

      expect(unchanged).to be_unchanged
      expect(unchanged.paths).to be_empty
      expect(unchanged.attention).to be_empty
    end

    it "answers full shas, which is what makes an entry joinable with a commit" do
      expect(delta.identical.first.new_sha).to eq(sha("amended~2"))
      expect(delta.identical.first.old_sha).to eq(sha("feature~2"))
    end

    it "anchors the reviewed range at the base as it WAS, not as it is now" do
      landed = delta_for("amended", base: "landed")

      expect(landed.identical.map(&:subject)).to eq(["feat: one", "feat: two"])
      expect(landed.changed.map(&:subject)).to eq(["feat: three"])
    end

    it "reads the padded form git switches to past nine entries" do
      padded = delta_for("padded")

      expect(padded.entries.size).to eq(13)
      expect(padded.added.size).to eq(10)
      expect(padded.added.last).to have_attributes(new_index: 13, subject: "pad 10")
      expect(padded.identical.map(&:old_index)).to eq([1, 2, 3])
    end

    # Pinned, not endorsed: `git range-diff` compares patch SERIES and a merge
    # has no patch, so it reports the side branch's commits and drops the merge
    # itself. The file that exists only in the hand resolution therefore belongs
    # to no entry at all. There is no flag that recovers it, and a reader is
    # better served meeting the hole here than mid-review.
    it "reports a merge as the commits it brought, and loses the hand resolution" do
      merged = delta_for("merged")

      expect(merged.added.map(&:subject)).to eq(["side one"])
      expect(merged.paths).to eq(["side_only.rb"])
      expect(merged.paths).not_to include("only_in_merge.rb")
      # The control: the file really is in the branch, so its absence above is
      # the primitive's doing and not the fixture's.
      expect(run_git("ls-tree", "-r", "--name-only", "merged")).to include("only_in_merge.rb")
    end

    it "freezes an entry all the way down" do
      expect(delta.entries.first).to be_deeply_frozen
    end
  end

  # Each of these fails with the pin removed and passes with it. A developer's
  # git config is what they are against, and none is hypothetical.
  describe "determinism against the configuration it is read under" do
    it "parses under a config that forces colour into a pipe" do
      config("color.ui", "always")

      expect(delta.changed.map(&:subject)).to eq(["feat: three"])
    end

    it "reports a commit carrying a git note identical, not changed" do
      run_git("notes", "add", "-m", "a note somebody left", sha("amended~2"))

      expect(delta.identical.map(&:subject)).to eq(["feat: one", "feat: two"])
    end

    it "answers full shas under a config that abbreviates them" do
      config("core.abbrev", "4")

      expect(delta.identical.first.new_sha).to eq(sha("amended~2"))
    end

    it "answers a UTF-8 subject under a config that spells log output latin-1" do
      commit_on("amended", "caf\xE9 subject".b, "w.rb" => "w\n")
      config("i18n.logOutputEncoding", "ISO-8859-1")

      subjects = delta.added.map(&:subject)
      expect(subjects).to eq(["café subject"])
      expect(subjects.first.encoding).to eq(Encoding::UTF_8)
    end

    # `core.quotePath` is the one setting this class does NOT pin, because
    # {Wire.unquote} inverts it exactly. This is the example that says so: the
    # config is turned ON, and the answer is the same.
    it "decodes a non-ASCII path a config chose to quote" do
      commit_on("amended", "a unicode path", "café.rb" => "unicode\n")
      config("core.quotePath", "true")

      expect(delta.paths).to include("café.rb")
    end

    it "decodes the C-quoting git applies whatever core.quotePath says" do
      commit_on("amended", "a quoted path", 'we"ird.rb' => "quoted\n")

      expect(delta.paths).to include('we"ird.rb')
    end

    # The one setting whose DEFAULT is the harmful one. This call carries no
    # `--no-patch`, so unlike the range-diff it is exposed to `diff.renames`,
    # and with detection on git lists a rename's destination alone -- dropping
    # the very path a reviewer needs to stop looking for.
    it "names both sides of a rename, which rename detection would hide" do
      run_git("checkout", "-q", "amended")
      run_git("mv", "u.rb", "renamed.rb")
      run_git("commit", "-q", "-m", "rename u.rb")

      expect(delta.paths).to include("u.rb", "renamed.rb")
    end

    it "keeps gpg's chatter out of the file names under log.showSignature" do
      sign_commits
      commit_on("amended", "a signed commit", "signed.rb" => "signed\n")
      config("log.showSignature", "true")

      expect(delta.paths).to eq(["big.rb", "signed.rb"])
    end

    # Under `.git/` so `add -A` never sees it; {SeedRepo}'s own config pins are
    # untouched apart from the gpgsign one this deliberately turns back on.
    def sign_commits
      program = File.join(@repo, ".git", "fake-gpg")
      File.write(program, ReviewDeltaRepo::FAKE_GPG)
      FileUtils.chmod(0o755, program)
      { "gpg.program" => program, "user.signingkey" => "fake", "commit.gpgsign" => "true" }
        .each { |key, value| config(key, value) }
    end
  end

  describe "refusals" do
    it "names which of the four revisions did not resolve" do
      expect { delta_for("no-such-branch") }
        .to raise_error(Lain::Review::Source::UnknownRef, /head ref "no-such-branch"/)
    end

    # A rev that resolves to a TREE resolves perfectly well; it just cannot be
    # one end of a range. `^{commit}` is the guard, and without it the refusal
    # would arrive later, from range-diff, about something else.
    it "refuses a rev that resolves to something other than a commit" do
      expect { delta_for("amended", base: "base^{tree}") }
        .to raise_error(Lain::Review::Source::UnknownRef, /base ref "base\^\{tree\}"/)
    end

    it "names the pinned side separately, since it is not the caller's typing" do
      expect do
        described_class.new(pinned_base: ReviewDeltaRepo::PINNED_BASE,
                            pinned_head: "refs/test/pinned/gone",
                            base: "base", head: "amended", repo_root: @repo)
      end.to raise_error(Lain::Review::Source::UnknownRef, /pinned head/)
    end

    # The `shell_out_factory` seam, for the two failures a real repository will
    # not produce on demand: a git with no `range-diff` subcommand, and one whose
    # output is not the format this parses. The escalation trigger for this card
    # says there is no fallback primitive, so both have to be loud.
    it "carries git's own words when range-diff could not run" do
      expect { delta_with(refusing_git("git: 'range-diff' is not a git command")).entries }
        .to raise_error(Lain::Review::Delta::Unreadable, /is not a git command/)
    end

    it "refuses a line it cannot read rather than dropping it" do
      expect { delta_with(answering_git("1: abc ~ 1: def a shape from the future\n")).entries }
        .to raise_error(Lain::Review::Delta::Unreadable, /a shape from the future/)
    end

    # The worst answer this class can give, and exactly what an unchecked exit
    # status produces: "git could not answer" wearing the clothes of "nothing
    # to re-read". The subject KNOWS a commit changed, so an empty file list
    # would contradict the same object's other answer in the same breath.
    it "refuses an empty file list that is really a failed git log" do
      broken = delta_with(failing_git("log", "fatal: bad object"))

      expect(broken.changed.map(&:subject)).to eq(["feat: three"])
      expect { broken.paths }.to raise_error(Lain::Review::Delta::Unreadable, /bad object/)
    end

    def delta_with(factory)
      described_class.new(pinned_base: ReviewDeltaRepo::PINNED_BASE,
                          pinned_head: ReviewDeltaRepo::PINNED_HEAD,
                          base: "base", head: "amended", repo_root: @repo,
                          shell_out_factory: factory)
    end

    # Only the named subcommand is faked; every other call runs for real, so the
    # constructor's four resolves still happen against the fixture.
    def intercepting_git(subcommand, fake)
      real = Mixlib::ShellOut.public_method(:new)
      lambda do |*args, **options|
        args.include?(subcommand) ? fake.call : real.call(*args, **options)
      end
    end

    def failing_git(subcommand, stderr)
      intercepting_git(subcommand,
                       -> { instance_double(Mixlib::ShellOut, run_command: nil, exitstatus: 1, stdout: "", stderr:) })
    end

    def refusing_git(stderr) = failing_git("range-diff", stderr)

    def answering_git(stdout)
      intercepting_git("range-diff",
                       -> { instance_double(Mixlib::ShellOut, run_command: nil, exitstatus: 0, stdout:, stderr: "") })
    end
  end

  describe Lain::Review::Delta::Pin do
    subject(:pin) { described_class.new(scope_key: "epic/review-surface", generation: 1, repo_root: @repo) }

    it "namespaces the ref where no add can check it out" do
      expect(pin.ref).to start_with("refs/lain/reviewed/")
      expect(pin.ref).to end_with("/1")
    end

    it "keeps two scope keys apart even when they slug the same" do
      other = described_class.new(scope_key: "epic-review-surface", generation: 1, repo_root: @repo)

      expect(other.ref).not_to eq(pin.ref)
    end

    it "keeps two generations of one scope apart" do
      second = described_class.new(scope_key: "epic/review-surface", generation: 2, repo_root: @repo)

      expect(second.ref).not_to eq(pin.ref)
    end

    it "refuses a scope key that is not one, because that is what collides" do
      expect { described_class.new(scope_key: "  ", generation: 1, repo_root: @repo) }
        .to raise_error(ArgumentError, /scope_key/)
    end

    it "refuses a generation that cannot be counted" do
      expect { described_class.new(scope_key: "pr-42", generation: 0, repo_root: @repo) }
        .to raise_error(ArgumentError, /generation/)
    end

    # git-check-ref-format refuses `..` and a leading `.`, and both are
    # reachable from an ordinary key -- `..foo` is a legal branch name and
    # `../../../heads/main` is what an escape out of the namespace looks like.
    # `check-ref-format` is the judge here rather than a regex of our own,
    # because it is the same program that will refuse the write.
    it "slugs a key that would escape the namespace into one git accepts" do
      %w[../../../heads/main ..foo .hidden foo.lock -dash].each do |key|
        ref = described_class.new(scope_key: key, generation: 1, repo_root: @repo).ref

        expect(ref).to start_with("refs/lain/reviewed/")
        expect { run_git("check-ref-format", ref) }.not_to raise_error, "#{key} slugged to #{ref}"
      end
    end

    it "keeps two escaping keys apart rather than slugging them together" do
      keys = ["../../../heads/main", "..foo", ".foo", "foo"]
      refs = keys.map { |key| described_class.new(scope_key: key, generation: 1, repo_root: @repo).ref }

      expect(refs.uniq.size).to eq(keys.size)
    end

    # Legal branch names whose every byte is outside a refname's alphabet. The
    # slug empties, but the fingerprint does not, so the review proceeds under a
    # ref that is merely unreadable rather than being blocked outright.
    it "pins a wholly non-ASCII scope key on its fingerprint alone" do
      cyrillic = described_class.new(scope_key: "эпик", generation: 1, repo_root: @repo)
      japanese = described_class.new(scope_key: "日本語のエピック", generation: 1, repo_root: @repo)

      expect { run_git("check-ref-format", cyrillic.ref) }.not_to raise_error
      expect(cyrillic.ref).not_to eq(japanese.ref)
      expect(cyrillic.write(sha("feature"))).to eq(sha("feature"))
    end

    it "reads back the head it pinned" do
      pinned = sha("feature")
      pin.write(pinned)

      expect(pin.resolve).to eq(pinned)
    end

    it "resolves a rev before writing it, so a bad head is the caller's mistake" do
      expect { pin.write("no-such-rev") }
        .to raise_error(Lain::Review::Source::UnknownRef, /pinned ref "no-such-rev"/)
    end

    # The card's own concurrent-reviews case. Folded into UnknownRef this read
    # `pinned ref "..." does not resolve to a commit` while git's appended words
    # said `cannot lock ref` -- a refusal contradicted in its own sentence.
    it "says the ref could not be WRITTEN when another git holds its lock" do
      lock = File.join(@repo, ".git", "#{pin.ref}.lock")
      FileUtils.mkdir_p(File.dirname(lock))
      FileUtils.touch(lock)

      expect { pin.write(sha("feature")) }
        .to raise_error(Lain::Review::Delta::Unpinnable, /could not pin.*cannot lock ref/m)
    end

    it "refuses a baseline that was never pinned, which is a first review" do
      expect(pin).not_to be_pinned
      expect { pin.resolve }.to raise_error(Lain::Review::Delta::NoBaseline, /#{pin.ref}/)
    end

    it "keeps the reviewed head reachable after the branch is rewritten and gc runs" do
      pinned = sha("feature")
      pin.write(pinned)
      rewrite_and_gc

      expect(pin.resolve).to eq(pinned)
      expect(run_git("cat-file", "-t", pinned).strip).to eq("commit")
    end

    it "is the only thing keeping it reachable" do
      pinned = sha("feature")
      rewrite_and_gc

      expect { run_git("cat-file", "-t", pinned) }.to raise_error(Mixlib::ShellOut::ShellCommandFailed)
    end

    # Everything else that could hold the reviewed head alive, removed -- and
    # ENUMERATED rather than listed by hand, because a branch added to the
    # fixture later would otherwise keep the object reachable on its own and
    # quietly make both examples below vacuous. One did exactly that: `landed`
    # merges the reviewed branch, so naming four branches was already wrong.
    def rewrite_and_gc
      run_git("checkout", "-q", "base")
      [ReviewDeltaRepo::PINNED_HEAD, ReviewDeltaRepo::PINNED_BASE].each { |ref| run_git("update-ref", "-d", ref) }
      others = run_git("for-each-ref", "--format=%(refname:short)", "refs/heads/").split("\n") - ["base"]
      run_git("branch", "-q", "-D", *others)
      run_git("reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all")
      run_git("gc", "--prune=now", "-q")
    end
  end
end
