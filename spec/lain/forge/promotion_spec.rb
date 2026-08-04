# frozen_string_literal: true

require "tmpdir"
require "mixlib/shellout"

# Operates on THROWAWAY repos it creates itself -- a local checkout plus a local
# BARE remote under one mktmpdir -- never the lain repo it runs in, and never the
# network. Same posture worktree_handback_spec.rb takes, and the reason this stays
# in the default suite: git is always present, GitHub is not.
RSpec.describe Lain::Forge::Promotion, :seam do
  subject(:promotion) { build_promotion }

  around do |example|
    Dir.mktmpdir("lain-promotion") do |dir|
      @repo_root = File.join(dir, "checkout")
      @remote_root = File.join(dir, "remote.git")
      example.run
    end
  end

  before do
    Dir.mkdir(@repo_root)
    Dir.mkdir(@remote_root)
    run_git(@remote_root, "init", "--bare", "-q")
    init_repo(@repo_root)
    run_git(@repo_root, "remote", "add", "origin", @remote_root)
  end

  let(:records) { [] }
  let(:calls) { [] }

  def build_promotion(slug: "demo", issue: "a1", factory: recording_factory(calls))
    described_class.new(repo_root: @repo_root, epic_slug: slug, issue_id: issue,
                        journaled: journaling(records), shell_out_factory: factory)
  end

  # The seam T17's {Forge::Journaled#attempt} exposes, stood up here as a double:
  # it takes the effect's ADDRESS, brackets the block with an intent and an
  # outcome, and hands the block's answer back unchanged. Promotion depends on
  # that message, never on the wrapper's type.
  #
  # It READS `ok?`, `observed?` and `detail` exactly as the real wrapper folds
  # them into a {Forge::Outcome}, so an answer that drifts off that shape fails
  # these specs here rather than raising inside a wrapper this spec cannot see --
  # a NoMethodError there lands AFTER the intent is journaled and before any
  # outcome is, which is the one record shape a reconcile must never be handed.
  def journaling(journal)
    recorder = Object.new
    recorder.define_singleton_method(:attempt) do |action:, params:, &effect|
      journal << { action:, params: }
      answer = effect.call
      journal << { ok: answer.ok?, observed: answer.observed?, detail: answer.detail, answer: }
      answer
    end
    recorder
  end

  def recording_factory(seen, delegate: Mixlib::ShellOut.public_method(:new))
    lambda do |*args, **kwargs|
      seen << { args:, kwargs: }
      delegate.call(*args, **kwargs)
    end
  end

  # Fails ONE git subcommand without running it, so a refusal git will not
  # produce on demand (a `check-ref-format` that rejects a name the grammar
  # already accepted) still gets pinned. Everything else runs for real.
  def factory_failing(subcommand, seen)
    real = Mixlib::ShellOut.public_method(:new)
    broken = Struct.new(:stdout, :stderr, :exitstatus) do
      def run_command = self
    end
    lambda do |*args, **kwargs|
      seen << { args:, kwargs: }
      args.include?(subcommand) ? broken.new("", "forced failure", 1) : real.call(*args, **kwargs)
    end
  end

  # The spec's OWN git calls scrub the git-context env too, so building and
  # inspecting the throwaway repos is hermetic under an ambient GIT_*-polluted
  # env (a pre-commit hook) exactly as the subject is -- reusing the pinned scrub
  # set rather than a parallel copy of it.
  def try_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command
    shell
  end

  def run_git(dir, *args) = try_git(dir, *args).tap(&:error!).stdout

  def init_repo(dir)
    run_git(dir, "init", "-q")
    run_git(dir, "config", "user.email", "test@example.com")
    run_git(dir, "config", "user.name", "Test")
    commit_in(dir, "seed\n", "seed")
  end

  def commit_in(dir, contents, message, file: "README")
    File.write(File.join(dir, file), contents)
    run_git(dir, "add", file)
    run_git(dir, "commit", "-q", "-m", message)
    run_git(dir, "rev-parse", "HEAD").strip
  end

  # The sha under test comes off a REAL handback anchor ref, named by the object
  # that decides that naming: a promotion's input is whatever `#anchor` left
  # behind, and a reconstructed namespace here would let the two drift.
  def anchored(worker_id = "worker-1")
    ref = Lain::Isolation::Worktree::Handback::Naming.new(worker_id).ref
    sha = commit_in(@repo_root, "#{worker_id}\n", "#{worker_id} work")
    run_git(@repo_root, "update-ref", "--create-reflog", ref, sha)
    run_git(@repo_root, "rev-parse", "--verify", ref).strip
  end

  # A commit on a history that does NOT reach the current branch tip: back to a
  # root commit, then forward. `anchored` alone only ever produces DESCENDANTS,
  # which git fast-forwards -- the one case a "diverged" refusal must not be
  # spec'd on exclusively.
  def sideways(from, worker_id = "worker-2")
    run_git(@repo_root, "checkout", "-q", from)
    anchored(worker_id)
  end

  def remote_ref(ref) = try_git(@remote_root, "rev-parse", "--verify", "--quiet", ref).stdout.strip

  def local_heads = run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/heads").split("\n")

  def argv = calls.map { |call| call[:args] }

  def git_verbs = argv.map { |args| args[3] }

  def intent = records.first

  def folded = records.last

  describe "promotion pushes without a local branch" do
    it "puts the anchored sha on the remote under refs/heads/epic/<slug>/<issue>" do
      sha = anchored

      result = promotion.call(sha:)

      expect(remote_ref("refs/heads/epic/demo/a1")).to eq(sha)
      expect(result).to be_ok
      expect(result).not_to be_observed
    end

    it "creates no local branch on the way" do
      before_heads = local_heads

      promotion.call(sha: anchored)

      expect(local_heads).to eq(before_heads)
      expect(local_heads.join("\n")).not_to include("epic/demo")
    end

    it "pushes the sha itself as the refspec source" do
      sha = anchored

      promotion.call(sha:)

      expect(argv).to include(array_including("push", "origin", "#{sha}:refs/heads/epic/demo/a1"))
    end

    it "addresses the intent by ref and sha, and by nothing cosmetic" do
      sha = anchored

      promotion.call(sha:)

      expect(intent[:action]).to eq(Lain::Forge::PROMOTE)
      expect(intent[:params]).to eq("ref" => "refs/heads/epic/demo/a1", "sha" => sha)
    end

    it "hands the journaled bracket's answer back unchanged" do
      sha = anchored

      result = promotion.call(sha:)

      expect(result).to be(folded[:answer])
      expect(folded).to include(ok: true, observed: false, detail: result.detail)
    end

    # {Forge::Outcome} carries only a digest, so a refusal a human has to act on
    # says which epic and issue it was for without a trip to the journal.
    it "names the epic, the issue, the ref and the sha in the detail" do
      sha = anchored

      result = promotion.call(sha:)

      expect(result.detail).to include("epic_slug" => "demo", "issue_id" => "a1", "reason" => "promoted",
                                       "ref" => "refs/heads/epic/demo/a1", "sha" => sha)
    end

    # A promotion may run from a pre-commit hook's environment, where GIT_DIR and
    # friends name some OTHER repository.
    it "scrubs the ambient git context on every subprocess" do
      promotion.call(sha: anchored)

      expect(calls).not_to be_empty
      expect(calls.map { |call| call[:kwargs][:environment] })
        .to all(eq(Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB))
    end
  end

  describe "promotion is idempotent by observation" do
    it "answers ok and observed the second time" do
      sha = anchored
      promotion.call(sha:)

      result = promotion.call(sha:)

      expect(result).to be_ok
      expect(result).to be_observed
      expect(result.detail["reason"]).to eq("already_promoted")
      expect(remote_ref("refs/heads/epic/demo/a1")).to eq(sha)
    end

    it "does not push again once the remote already holds the sha" do
      sha = anchored
      promotion.call(sha:)
      calls.clear

      promotion.call(sha:)

      expect(git_verbs).not_to include("push")
    end

    it "journals a second intent/outcome pair under the same address" do
      sha = anchored
      promotion.call(sha:)

      promotion.call(sha:)

      expect(records.size).to eq(4)
      expect(records[2][:params]).to eq(records[0][:params])
    end

    it "never reaches for a force flag on any path" do
      sha = anchored
      promotion.call(sha:)
      promotion.call(sha:)

      expect(argv.flatten.grep(/\A--force/)).to be_empty
    end
  end

  # "Diverged" here means the ref stands anywhere this promotion did not put it,
  # which covers two histories that git treats very differently. Both are pinned,
  # because the FAST-FORWARD one is the case a user is most likely to hit and the
  # one where the card's rule and an expectation openly disagree: git would take
  # that push, and this refuses it anyway. Nothing here forces either way.
  describe "a remote branch standing somewhere else refuses" do
    it "answers not ok, says diverged, and names the sha the remote holds" do
      taken = anchored("worker-1")
      promotion.call(sha: taken)

      result = promotion.call(sha: anchored("worker-2"))

      expect(result).not_to be_ok
      expect(result).not_to be_observed
      expect(result.detail["reason"]).to eq("diverged")
      expect(result.detail["message"]).to include(taken)
    end

    it "leaves the remote ref exactly where it was, without pushing" do
      taken = anchored("worker-1")
      promotion.call(sha: taken)
      calls.clear

      promotion.call(sha: anchored("worker-2"))

      expect(remote_ref("refs/heads/epic/demo/a1")).to eq(taken)
      expect(git_verbs).not_to include("push")
    end

    it "still journals the pair" do
      promotion.call(sha: anchored("worker-1"))
      records.clear

      promotion.call(sha: anchored("worker-2"))

      expect(records.size).to eq(2)
      expect(records.first[:action]).to eq(Lain::Forge::PROMOTE)
    end

    # The two examples above promote sequential commits on one branch, so the
    # second sha is a strict DESCENDANT of the first -- a fast-forward git would
    # accept. The genuinely non-linear case, where neither sha reaches the other,
    # is a different history and gets its own example rather than an assumption.
    it "refuses a remote sha that neither reaches nor is reached by this one" do
      root = run_git(@repo_root, "rev-parse", "HEAD").strip
      theirs = anchored("worker-1")
      promotion.call(sha: theirs)
      mine = sideways(root)
      calls.clear

      result = promotion.call(sha: mine)

      expect(result.detail["reason"]).to eq("diverged")
      expect(remote_ref("refs/heads/epic/demo/a1")).to eq(theirs)
      expect(git_verbs).not_to include("push")
    end

    it "refuses a fast-forward the bare push would have taken" do
      old = anchored("worker-1")
      promotion.call(sha: old)
      newer = anchored("worker-2")

      expect(promotion.call(sha: newer).detail["reason"]).to eq("diverged")
      expect(try_git(@repo_root, "merge-base", "--is-ancestor", old, newer).exitstatus).to eq(0)
    end

    # A refusal that names only state leaves a human to guess whether force was
    # unavailable, forgotten, or withheld. It was withheld.
    it "says force was withheld and whose decision the advance is" do
      taken = anchored("worker-1")
      promotion.call(sha: taken)
      sha = anchored("worker-2")

      message = promotion.call(sha:).detail["message"]

      expect(message).to include(taken, sha)
      expect(message).to include("never forces")
      expect(message).to include("cascade")
    end
  end

  describe "a ref the namespace cannot hold" do
    it "refuses when a branch occupies the epic directory" do
      sha = anchored
      run_git(@repo_root, "push", "-q", "origin", "#{sha}:refs/heads/epic/demo")
      calls.clear

      result = promotion.call(sha:)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("namespace_conflict")
      expect(result.detail["message"]).to include("refs/heads/epic/demo")
      expect(git_verbs).not_to include("push")
    end

    # Refs are paths, and no flag makes a name be both a file and a directory --
    # so unlike a divergence there is exactly one way forward, and the refusal
    # names it rather than leaving a reader to work out that git is immovable here.
    it "says what has to happen to the occupying ref" do
      sha = anchored
      run_git(@repo_root, "push", "-q", "origin", "#{sha}:refs/heads/epic/demo")

      message = promotion.call(sha:).detail["message"]

      expect(message).to include("refs/heads/epic/demo")
      expect(message).to include("delete or rename")
    end

    it "refuses when the ref would have to become a directory" do
      sha = anchored
      run_git(@repo_root, "push", "-q", "origin", "#{sha}:refs/heads/epic/demo/a1/extra")
      calls.clear

      result = promotion.call(sha:)

      expect(result.detail["reason"]).to eq("namespace_conflict")
      expect(result.detail["message"]).to include("refs/heads/epic/demo/a1/extra")
      expect(git_verbs).not_to include("push")
    end

    it "does not mistake a sibling issue's branch for a conflict" do
      sha = anchored
      run_git(@repo_root, "push", "-q", "origin", "#{sha}:refs/heads/epic/demo/a2")

      expect(promotion.call(sha:)).to be_ok
      expect(remote_ref("refs/heads/epic/demo/a1")).to eq(sha)
    end
  end

  describe "names checked before anything runs" do
    it "refuses a slug the filesystem grammar refuses, at construction" do
      expect { build_promotion(slug: "../escape") }
        .to raise_error(Lain::Epic::Home::MalformedName, /epic slug/)
      expect(calls).to be_empty
    end

    it "refuses an issue id the filesystem grammar refuses, at construction" do
      expect { build_promotion(issue: "A1/b") }.to raise_error(Lain::Epic::Home::MalformedName, /issue id/)
      expect(calls).to be_empty
    end

    # Three interned strings and no mutable state, so the house rule for a value
    # object applies: `Ractor.shareable?` is the mechanical statement of that,
    # and it is false for an unfrozen object however immutable its contents.
    it "composes a ref that is a deeply frozen value" do
      expect(described_class::Branch.new(epic_slug: "demo", issue_id: "a1")).to be_deeply_frozen
    end

    # The canary for the two rules drifting apart: the name grammar cannot spell
    # a ref git refuses today, so this refusal has to be forced rather than
    # provoked.
    it "refuses a composed ref git will not accept" do
      sha = anchored
      seen = []

      result = build_promotion(factory: factory_failing("check-ref-format", seen)).call(sha:)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("malformed_ref")
      expect(seen.map { |call| call[:args][3] }).not_to include("push")
    end
  end

  describe "the sha it is handed is the address it journals" do
    it "raises when handed no sha at all" do
      expect { promotion.call(sha: "  ") }.to raise_error(described_class::Unanchored)
      expect(calls).to be_empty
      expect(records).to be_empty
    end

    it "refuses a commit the checkout does not have" do
      anchored
      calls.clear

      result = promotion.call(sha: "0" * 40)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("unknown_commit")
      expect(git_verbs).not_to include("push")
    end

    # A reconcile asks the world `sha_of(ref) == params["sha"]`, so the address
    # has to be the full object name. `HEAD`, a branch name or an abbreviation
    # resolves locally and then never compares equal to what the remote reports.
    it "refuses a commit-ish that is not the object name itself" do
      anchored
      calls.clear

      result = promotion.call(sha: "HEAD")

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("inexact_sha")
      expect(git_verbs).not_to include("push")
    end
  end

  describe "git refusing" do
    it "reports an unreachable remote rather than raising" do
      sha = anchored
      run_git(@repo_root, "remote", "remove", "origin")

      result = promotion.call(sha:)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("remote_unreachable")
    end

    # `observed` entails success: it means the effect was found ALREADY in place
    # and confirmed. A refusal carrying it would tell a reconcile the push landed
    # from a promotion that never reached the remote.
    #
    # The invariant is held by CONSTRUCTION, not by this file: the answer is the
    # guarded {Gh::Answer}, whose {Gh::Guards::Answer} refuses the pair outright.
    # A value of our own that merely never happened to be built wrong would put
    # the same guarantee back in the hands of whoever edits `#answer` next.
    it "answers the guarded Gh::Answer rather than a twin of its own" do
      expect(promotion.call(sha: anchored)).to be_a(Lain::Forge::Gh::Answer)
      expect { Lain::Forge::Gh::Answer.new(ok: false, observed: true) }
        .to raise_error(ArgumentError, /observed/)
    end

    it "never claims to have observed a refusal" do
      sha = anchored
      run_git(@repo_root, "push", "-q", "origin", "#{sha}:refs/heads/epic/demo")

      refusals = [promotion.call(sha:), promotion.call(sha: "HEAD"), promotion.call(sha: "0" * 40)]

      expect(refusals.map(&:ok?)).to all(be(false))
      expect(refusals.map(&:observed?)).to all(be(false))
    end

    it "reports a refused push in git's own words" do
      sha = anchored

      result = build_promotion(factory: factory_failing("push", [])).call(sha:)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("push_failed")
      expect(result.detail["message"]).to include("forced failure")
      expect(remote_ref("refs/heads/epic/demo/a1")).to be_empty
    end
  end
end
