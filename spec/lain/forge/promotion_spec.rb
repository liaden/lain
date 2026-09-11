# frozen_string_literal: true

require "tmpdir"
require "mixlib/shellout"

# Operates on THROWAWAY repos it creates itself -- a local checkout plus a local
# BARE remote under one mktmpdir -- never the lain repo it runs in, and never the
# network. git is always present, GitHub is not.
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

  def ref = "refs/heads/epic/demo"

  def build_promotion(slug: "demo", factory: recording_factory(calls))
    described_class.new(repo_root: @repo_root, epic_slug: slug, journaled: journaling(records),
                        shell_out_factory: factory)
  end

  # The seam {Forge::Journaled#attempt} exposes, stood up as a double that READS
  # `ok?`, `observed?` and `detail` exactly as the real wrapper folds them into
  # a {Forge::Outcome}, so an answer that drifts off that shape fails here.
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
  # produce on demand still gets pinned. Everything else runs for real.
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

  # Scrubbed exactly as the subject scrubs, so building the throwaway repos is
  # hermetic under a pre-commit hook's GIT_* environment.
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

  # The epic branch's tip, as a commit this checkout holds.
  def landed(label = "epic work") = commit_in(@repo_root, "#{label}\n", label)

  # A commit on a history that does NOT reach the current tip: back to a root
  # commit, then forward, so a "diverged" refusal is not spec'd on descendants
  # alone.
  def sideways(from, label)
    run_git(@repo_root, "checkout", "-q", from)
    landed(label)
  end

  def remote_ref(name = ref) = try_git(@remote_root, "rev-parse", "--verify", "--quiet", name).stdout.strip

  def local_heads = run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/heads").split("\n")

  def argv = calls.map { |call| call[:args] }

  def git_verbs = argv.map { |args| args[3] }

  def intent = records.first

  def folded = records.last

  describe "the epic goes to the remote as one branch" do
    it "puts the epic branch's sha on the remote under refs/heads/epic/<slug>" do
      sha = landed

      result = promotion.call(sha:)

      expect(remote_ref).to eq(sha)
      expect(result).to be_ok
      expect(result).not_to be_observed
    end

    it "creates no local branch on the way" do
      before_heads = local_heads

      promotion.call(sha: landed)

      expect(local_heads).to eq(before_heads)
    end

    it "pushes the sha itself as the refspec source" do
      sha = landed

      promotion.call(sha:)

      expect(argv).to include(array_including("push", "origin", "#{sha}:#{ref}"))
    end

    it "addresses the intent by ref and sha, and by nothing cosmetic" do
      sha = landed

      promotion.call(sha:)

      expect(intent[:action]).to eq(Lain::Forge::PROMOTE)
      expect(intent[:params]).to eq("ref" => ref, "sha" => sha)
    end

    it "hands the journaled bracket's answer back unchanged" do
      sha = landed

      result = promotion.call(sha:)

      expect(result).to be(folded[:answer])
      expect(folded).to include(ok: true, observed: false, detail: result.detail)
    end

    it "names the epic, the ref and the sha in the detail" do
      sha = landed

      expect(promotion.call(sha:).detail)
        .to include("epic_slug" => "demo", "reason" => "promoted", "ref" => ref, "sha" => sha)
    end

    it "scrubs the ambient git context on every subprocess" do
      promotion.call(sha: landed)

      expect(calls).not_to be_empty
      expect(calls.map { |call| call[:kwargs][:environment] })
        .to all(eq(Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB))
    end
  end

  describe "promotion is idempotent by observation" do
    it "answers ok and observed the second time, without pushing again" do
      sha = landed
      promotion.call(sha:)
      calls.clear

      result = promotion.call(sha:)

      expect(result).to be_ok
      expect(result).to be_observed
      expect(result.detail["reason"]).to eq("already_promoted")
      expect(git_verbs).not_to include("push")
    end

    it "journals a second intent/outcome pair under the same address" do
      sha = landed
      promotion.call(sha:)

      promotion.call(sha:)

      expect(records.size).to eq(4)
      expect(records[2][:params]).to eq(records[0][:params])
    end

    it "never reaches for a force flag on any path" do
      sha = landed
      promotion.call(sha:)
      promotion.call(sha:)
      promotion.delete(sha:)

      expect(argv.flatten.grep(/\A--force/)).to be_empty
    end
  end

  describe "a remote branch standing somewhere else refuses" do
    it "answers not ok, says diverged, names the sha the remote holds, and pushes nothing" do
      taken = landed("first")
      promotion.call(sha: taken)
      calls.clear

      result = promotion.call(sha: landed("second"))

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("diverged")
      expect(result.detail["message"]).to include(taken, "never forces")
      expect(remote_ref).to eq(taken)
      expect(git_verbs).not_to include("push")
    end

    it "refuses a remote sha that neither reaches nor is reached by this one" do
      root = run_git(@repo_root, "rev-parse", "HEAD").strip
      theirs = landed("theirs")
      promotion.call(sha: theirs)

      result = promotion.call(sha: sideways(root, "mine"))

      expect(result.detail["reason"]).to eq("diverged")
      expect(remote_ref).to eq(theirs)
    end
  end

  # git holds a ref or a directory of refs at one name, never both, so
  # per-issue branches the old promotion left on the remote make the epic
  # branch unpushable. They are named, all of them, and none is deleted.
  describe "a remote the epic branch cannot be pushed into" do
    it "refuses, naming every per-issue branch left under the epic's name, and deletes none" do
      sha = landed
      %w[a1 a2].each { |issue| run_git(@repo_root, "push", "-q", "origin", "#{sha}:#{ref}/#{issue}") }
      calls.clear

      result = promotion.call(sha:)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("namespace_conflict")
      expect(result.detail["message"]).to include("#{ref}/a1", "#{ref}/a2", "delete or rename")
      expect([remote_ref("#{ref}/a1"), remote_ref("#{ref}/a2")]).to all(eq(sha))
      expect(git_verbs).not_to include("push")
    end

    it "refuses when a branch occupies the directory the epic branch sits in" do
      sha = landed
      run_git(@repo_root, "push", "-q", "origin", "#{sha}:refs/heads/epic")

      result = promotion.call(sha:)

      expect(result.detail["reason"]).to eq("namespace_conflict")
      expect(result.detail["message"]).to include("refs/heads/epic ")
    end

    it "does not mistake another epic's branches for a conflict" do
      sha = landed
      run_git(@repo_root, "push", "-q", "origin", "#{sha}:refs/heads/epic/other/a1")

      expect(promotion.call(sha:)).to be_ok
      expect(remote_ref).to eq(sha)
    end
  end

  describe "names checked before anything runs" do
    it "refuses a slug the filesystem grammar refuses, at construction" do
      expect { build_promotion(slug: "../escape") }.to raise_error(Lain::Epic::Home::MalformedName, /epic slug/)
      expect(calls).to be_empty
    end

    it "composes a ref that is a deeply frozen value" do
      expect(described_class::Branch.new(epic_slug: "demo")).to be_deeply_frozen
    end

    it "refuses a composed ref git will not accept" do
      sha = landed
      seen = []

      result = build_promotion(factory: factory_failing("check-ref-format", seen)).call(sha:)

      expect(result.detail["reason"]).to eq("malformed_ref")
      expect(seen.map { |call| call[:args][3] }).not_to include("push")
    end
  end

  describe "the sha it is handed is the address it journals" do
    it "raises when handed no sha at all, before anything is journaled" do
      expect { promotion.call(sha: "  ") }.to raise_error(described_class::Unanchored)
      expect { promotion.delete(sha: "  ") }.to raise_error(described_class::Unanchored)
      expect(records).to be_empty
    end

    it "refuses a commit the checkout does not have" do
      expect(promotion.call(sha: "0" * 40).detail["reason"]).to eq("unknown_commit")
    end

    it "refuses a commit-ish that is not the object name itself" do
      landed

      expect(promotion.call(sha: "HEAD").detail["reason"]).to eq("inexact_sha")
    end
  end

  describe "git refusing" do
    it "reports an unreachable remote rather than raising" do
      sha = landed
      run_git(@repo_root, "remote", "remove", "origin")

      expect(promotion.call(sha:).detail["reason"]).to eq("remote_unreachable")
    end

    it "answers the guarded Gh::Answer, which cannot claim to have observed a refusal" do
      expect(promotion.call(sha: landed)).to be_a(Lain::Forge::Gh::Answer)
      expect { Lain::Forge::Gh::Answer.new(ok: false, observed: true) }.to raise_error(ArgumentError, /observed/)
    end

    it "reports a refused push in git's own words" do
      result = build_promotion(factory: factory_failing("push", [])).call(sha: landed)

      expect(result.detail["reason"]).to eq("push_failed")
      expect(result.detail["message"]).to include("forced failure")
      expect(remote_ref).to be_empty
    end
  end

  # Once the epic's pull request is merged its remote branch has nothing left
  # to carry. The delete is the same kind of reach as the push: journaled as
  # an intent first, observed rather than remembered, and never forced.
  describe "deleting the remote branch once merged" do
    it "deletes the branch standing at the promoted sha, as a journaled branch_delete" do
      sha = landed
      promotion.call(sha:)
      records.clear

      result = promotion.delete(sha:)

      expect(result).to be_ok
      expect(result).not_to be_observed
      expect(result.detail["reason"]).to eq("deleted")
      expect(remote_ref).to be_empty
      expect(intent).to eq(action: Lain::Forge::BRANCH_DELETE, params: { "ref" => ref, "sha" => sha })
      expect(argv).to include(array_including("push", "origin", "--delete", ref))
    end

    it "counts a branch GitHub already deleted as done, without pushing" do
      sha = landed
      calls.clear

      result = promotion.delete(sha:)

      expect(result).to be_ok
      expect(result).to be_observed
      expect(result.detail["reason"]).to eq("already_deleted")
      expect(git_verbs).not_to include("push")
    end

    it "refuses to delete a branch that moved on after the merge, and leaves it" do
      promoted = landed("promoted")
      promotion.call(sha: promoted)
      later = landed("pushed after")
      run_git(@repo_root, "push", "-q", "origin", "#{later}:#{ref}")

      result = promotion.delete(sha: promoted)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("diverged")
      expect(result.detail["message"]).to include(later)
      expect(remote_ref).to eq(later)
    end

    it "stops on a delete git refuses, in git's own words" do
      sha = landed
      promotion.call(sha:)

      result = build_promotion(factory: factory_failing("push", [])).delete(sha:)

      expect(result).not_to be_ok
      expect(result.detail["reason"]).to eq("delete_failed")
      expect(result.detail["message"]).to include("forced failure")
      expect(remote_ref).to eq(sha)
    end
  end
end
