# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Drives real git in a throwaway repository: the parent checkout stands on
# main, and workers' commits are anchored where a handback anchors them.
RSpec.describe Lain::Isolation::CandidateDesk, :seam do
  include HeldParentLock

  around do |example|
    Dir.mktmpdir("lain-candidate-desk") do |repo|
      Dir.mktmpdir("lain-candidate-state") do |state|
        @repo = File.realpath(repo)
        @state = File.realpath(state)
        FileUtils.cp_r("#{SeedRepo.at({ "f" => "a\nb\nc\n", "h" => "x\n" })}/.", @repo)
        git("branch", "-M", "main")
        example.run
      end
    end
  end

  let(:queue_class) { Lain::Isolation::LandingQueue }
  let(:branch) { "main" }
  let(:journal) { [] }
  let(:resolver) { queue_class::Resolver::Standing }
  let(:verified) { [] }
  let(:verify) { passing }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @state, "XDG_STATE_HOME" => @state }) }
  let(:base) { Lain::Isolation::WorkingBranch.new(branch, repo_root: @repo, git: Lain::Isolation::Checkout.new(@repo)) }
  let(:desk) do
    described_class.new(
      repo_root: @repo, base:, journal:, strategy: Lain::Isolation::MergeStrategy::DEFAULT,
      home: Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch:),
      checkout: Lain::Isolation::VerifyCheckout.for(repo_root: @repo, branch:, paths:, keep: []),
      shell_out_factory: Lain::Shell::Out.public_method(:new)
    )
  end
  let(:queue) { queue_class.new(repo_root: @repo, base:, desk:, resolver:, verify:) }

  def passing = verdict(:passed)

  def verdict(outcome, detail: "", &before)
    lambda do |candidate|
      verified << { candidate:, merging: merging? }
      before&.call(candidate)
      queue_class::Verification.new(outcome:, tip: candidate.sha, detail:)
    end
  end

  def git(*) = SeedRepo.git(@repo, *).stdout.strip

  def git_in(dir, *) = SeedRepo.git(dir, *).stdout.strip

  def tip(name = branch) = git("rev-parse", "refs/heads/#{name}")

  # Scrubbed as the subject scrubs, and answering a nonzero exit rather than raising.
  def asked?(*args)
    Lain::Shell::Out.new("git", "-C", @repo, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command.exitstatus.zero?
  end

  def contains?(sha, name = branch) = asked?("merge-base", "--is-ancestor", sha, "refs/heads/#{name}")

  def merging? = asked?("rev-parse", "--verify", "--quiet", "MERGE_HEAD")

  def candidate_refs = git("for-each-ref", "--format=%(refname)", "refs/lain/candidate/")

  def handbacks = journal.grep(Lain::Telemetry::Handback)

  def commit_in(dir, name, body)
    File.write(File.join(dir, name), body)
    git_in(dir, "add", name)
    git_in(dir, "commit", "-q", "-m", "#{name} in #{File.basename(dir)}")
    git_in(dir, "rev-parse", "HEAD")
  end

  # A worker's committed work, cut from `from` and anchored under the ref a
  # handback would write, with the parent put back where it stood.
  def worker(id, from: tip, **files)
    standing = git("branch", "--show-current")
    git("switch", "-q", "--detach", from)
    files.each { |path, body| File.write(File.join(@repo, path.to_s), body) }
    git("add", *files.keys.map(&:to_s))
    git("commit", "-q", "-m", "#{id} work")
    sha = git("rev-parse", "HEAD")
    ref = Lain::Isolation::Worktree::Handback::Naming.new(id).ref
    git("update-ref", ref, sha)
    git("switch", "-q", standing)
    queue_class::Worker.new(id:, ref:, sha:)
  end

  describe "a green batch" do
    it "fast-forwards main once to a commit holding both workers, never merging in the parent" do
      older = tip
      at_t = commit_in(@repo, "h", "moved on\n")
      w1 = worker("w1", from: older, f: "a\nB1\nc\n")
      w2 = worker("w2", from: older, g: "new\n")

      result = queue.call([w1, w2])

      expect([contains?(w1.sha), contains?(w2.sha), contains?(at_t)]).to eq([true, true, true])
      expect(verified.map { |each| [each[:candidate].sha, each[:merging]] }).to eq([[tip, false]])
      expect(verified.first[:candidate].path).not_to eq(@repo)
      expect([merging?, git("status", "--porcelain"), git("rev-parse", "HEAD")]).to eq([false, "", tip])
      expect(handbacks.map { |record| [record.worker_key, record.outcome, record.ref] })
        .to eq([[Lain::Isolation::Worktree::Handback::Naming.new("w1").key, :merged, w1.ref],
                [Lain::Isolation::Worktree::Handback::Naming.new("w2").key, :merged, w2.ref]])
      expect([result.report("w1").kind, result.report("w2").kind, result.stale_tip]).to eq([:merged, :merged, false])
      expect(candidate_refs).to eq("")
    end

    it "fast-forwards whatever the repository's merge config says" do
      git("config", "branch.main.mergeOptions", "--squash")
      git("config", "merge.verifySignatures", "true")
      w1 = worker("w1", f: "a\nB1\nc\n")

      result = queue.call([w1])

      expect([tip, result.report("w1").kind, handbacks.size]).to eq([verified.first[:candidate].sha, :merged, 1])
    end

    it "waits on the parent checkout's lock to move the branch, telling the notice who holds it" do
      stub_const("Lain::Isolation::ParentLock::PATIENCE", 0.1)
      w1 = worker("w1", f: "a\nB1\nc\n")
      told = []
      waiting = queue_class.new(repo_root: @repo, base:, desk:, verify:, notice: ->(text) { told << text })
      landing = nil

      while_held_elsewhere(@repo) do |pid|
        landing = Thread.new { waiting.call([w1]) }
        expect(landing.join(0.5)).to be_nil
        expect([verified.size, contains?(w1.sha), told.join]).to match([1, false, a_string_including(pid.to_s)])
      end

      expect([landing.value.report("w1").kind, contains?(w1.sha)]).to eq([:merged, true])
    end

    it "lands under the default skipped verification, since nothing configured is not a failure" do
      w1 = worker("w1", f: "a\nB1\nc\n")

      result = queue_class.new(repo_root: @repo, base:, desk:).call([w1])

      expect([contains?(w1.sha), result.verification.outcome, handbacks.map(&:fast_forward)])
        .to eq([true, :skipped, [true]])
    end
  end

  describe "a red batch" do
    let(:verify) { verdict(:failed, detail: "3 examples failed") }

    it "leaves the branch and the journal untouched, and both reports say verification failed" do
      at_t = tip
      w1 = worker("w1", f: "a\nB1\nc\n")
      w2 = worker("w2", g: "new\n")

      result = queue.call([w1, w2])

      expect([tip, handbacks, candidate_refs]).to eq([at_t, [], ""])
      expect([result.report("w1"), result.report("w2")])
        .to all(have_attributes(kind: :declined, detail: a_string_including("3 examples failed")))
      expect(git("rev-parse", w1.ref)).to eq(w1.sha)
    end
  end

  describe "a commit landing on the branch during verification" do
    let(:verify) { verdict(:passed) { commit_in(@repo, "k", "racing\n") } }

    it "is caught, not overwritten, and the result says stale_tip" do
      w1 = worker("w1", f: "a\nB1\nc\n")

      result = queue.call([w1])

      expect(git("log", "-1", "--format=%s", branch)).to eq("k in #{File.basename(@repo)}")
      expect([contains?(w1.sha), result.stale_tip, handbacks, candidate_refs]).to eq([false, true, [], ""])
    end
  end

  describe "a branch moved backward during verification" do
    let(:verify) { verdict(:passed) { git("reset", "-q", "--hard", "HEAD~1") } }

    it "is stale, and the candidate is not landed over the rewind" do
      commit_in(@repo, "h", "moved on\n")
      w1 = worker("w1", f: "a\nB1\nc\n")

      result = queue.call([w1])

      expect([contains?(w1.sha), result.stale_tip, handbacks, candidate_refs]).to eq([false, true, [], ""])
    end
  end

  describe "a dirty parent file the candidate writes" do
    it "declines the batch naming only that file, and raises nothing" do
      at_t = tip
      w1 = worker("w1", f: "a\nB1\nc\n", g: "new\n")
      File.write(File.join(@repo, "f"), "edited by hand\n")
      File.write(File.join(@repo, "h"), "also edited\n")

      result = queue.call([w1])

      expect(result.report("w1"))
        .to have_attributes(kind: :declined, detail: a_string_ending_with("where the batch writes: f"))
      expect([tip, File.read(File.join(@repo, "f")), handbacks, result.stale_tip, candidate_refs])
        .to eq([at_t, "edited by hand\n", [], false, ""])
    end
  end

  describe "a staged rename of a file the candidate writes" do
    it "names the renamed-away path, not only its new name" do
      w1 = worker("w1", h: "y\n")
      git("mv", "h", "h2")

      result = queue.call([w1])

      expect(result.report("w1").detail).to end_with("where the batch writes: h")
    end
  end

  describe "a branch checked out in another worktree" do
    let(:branch) { "epic/demo" }

    it "fast-forwards that worktree and leaves the parent's HEAD and index alone" do
      git("branch", branch)
      landings = File.join(@state, "landings-demo")
      git("worktree", "add", "-q", landings, branch)
      w1 = worker("w1", from: tip, f: "a\nB1\nc\n")
      w2 = worker("w2", from: tip, g: "new\n")
      before = [git("symbolic-ref", "HEAD"), git("rev-parse", "HEAD"), git("ls-files", "-s")]

      queue.call([w1, w2])

      expect([git_in(landings, "rev-parse", "HEAD"), git_in(landings, "status", "--porcelain")]).to eq([tip, ""])
      expect([contains?(w1.sha), contains?(w2.sha)]).to eq([true, true])
      expect([git("symbolic-ref", "HEAD"), git("rev-parse", "HEAD"), git("ls-files", "-s")]).to eq(before)
      expect(candidate_refs).to eq("")
    end
  end

  describe "a branch checked out nowhere" do
    let(:branch) { "side" }

    it "moves by compare-and-swap" do
      git("branch", branch)
      w1 = worker("w1", from: tip, f: "a\nB1\nc\n")
      w2 = worker("w2", from: tip, g: "new\n")

      queue.call([w1, w2])

      expect([tip, candidate_refs]).to eq([verified.first[:candidate].sha, ""])
      expect([contains?(w1.sha), contains?(w2.sha)]).to eq([true, true])
    end

    context "when another writer moves it during verification" do
      let(:verify) do
        verdict(:passed) do
          racing = git("commit-tree", "#{branch}^{tree}", "-p", branch, "-m", "racing")
          git("update-ref", "refs/heads/#{branch}", racing)
        end
      end

      it "loses the compare-and-swap and says stale_tip" do
        git("branch", branch)
        w1 = worker("w1", from: tip, f: "a\nB1\nc\n")

        result = queue.call([w1])

        expect(git("log", "-1", "--format=%s", branch)).to eq("racing")
        expect([contains?(w1.sha), result.stale_tip, handbacks, candidate_refs]).to eq([false, true, [], ""])
      end
    end

    context "when a deleted worktree is still listed as holding it" do
      let(:gone) { File.join(@state, "gone") }
      let(:listed) { [] }
      let(:verify) do
        verdict(:passed) do
          FileUtils.rm_rf(gone)
          listed << git("worktree", "list", "--porcelain")
        end
      end

      it "counts the prunable entry as holding nothing, and moves by compare-and-swap" do
        git("branch", branch)
        git("worktree", "add", "-q", gone, branch)
        w1 = worker("w1", from: tip, f: "a\nB1\nc\n")

        result = queue.call([w1])

        expect(listed.first).to include("branch refs/heads/#{branch}\nprunable")
        expect([tip, result.report("w1").kind, candidate_refs]).to eq([verified.first[:candidate].sha, :merged, ""])
      end
    end
  end

  describe "a conflicting worker" do
    it "is skipped and the rest still land, its work on its ref" do
      commit_in(@repo, "f", "a\nTIP\nc\n")
      w1 = worker("w1", from: "HEAD~1", f: "a\nB1\nc\n")
      w2 = worker("w2", g: "new\n")

      result = queue.call([w1, w2])

      expect([contains?(w2.sha), contains?(w1.sha)]).to eq([true, false])
      expect(result.report("w1")).to have_attributes(kind: :conflicted, paths: ["f"], ref: w1.ref)
      expect(git("rev-parse", w1.ref)).to eq(w1.sha)
      expect([handbacks.map(&:worker_key), candidate_refs]).to eq([["w2"], ""])
    end

    context "with a spawned resolver" do
      let(:resolver) { queue_class::Resolver::Spawned.new(spawn:) }
      let(:spawn) do
        lambda do |_role, _mode, _prompt|
          File.write(File.join(desk.repo_root, "f"), "a\nB1 and B3\nc\n")
          Lain::Tool::Result.ok("kept both sides")
        end
      end

      it "resolves in the scratch checkout and lands the resolution, the parent never mid-merge" do
        w1 = worker("w1", f: "a\nB1\nc\n")
        w3 = worker("w3", f: "a\nB3\nc\n")

        result = queue.call([w1, w3])

        expect(result.report("w3").kind).to eq(:resolved)
        expect(git("show", "#{branch}:f")).to eq("a\nB1 and B3\nc")
        expect([contains?(w1.sha), contains?(w3.sha), merging?, desk.repo_root == @repo])
          .to eq([true, true, false, false])
        expect(handbacks.map { |record| [record.worker_key, record.outcome] }).to eq([["w1", :merged], ["w3", :merged]])
      end
    end
  end
end
