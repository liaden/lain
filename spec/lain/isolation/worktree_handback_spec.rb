# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# Operates on a THROWAWAY repo it copies per example ({SeedRepo}), never the lain
# repo it runs in -- the same posture worktree_spec.rb takes, and the reason this
# stays in the default suite: git is always present, docker is not.
#
# == Why this file is long, and why it stays ONE file
#
# It is the slowest file in the suite (~12s, 72 examples at a uniform ~0.17s) and
# therefore sets the floor on a parallel run, since parallel_tests packs whole
# FILES. Splitting it was considered and rejected, and the three questions worth
# asking were all answered no:
#
# * REDUNDANT? No. The 17 `#anchor` examples name 17 distinct invariants --
#   idempotence, an unmoved worktree, a parent that already has the commits, a
#   dirty parent, a mid-merge parent, not blocking a later `#call`, the
#   compare-and-swap on the ref's old value, reflog attributability, and the
#   `rescue Exception` journal case the subject documents at length.
# * INTEGRATION WITH WHAT? `:api_integration` is "hits the real API and costs
#   money", which this is not. It IS integration with the rest of lain, and that
#   tier now has a name: this file is tagged `:seam`.
# * IS THE SUBJECT DOING TOO MUCH? No, and this is the one that would have
#   justified splitting. {Handback}'s four public verbs are four lines each over
#   one shared vocabulary -- `Naming`, `journaled`, `broke`, `Checkout` -- with a
#   single invariant (never raise, always journal). It carries no `ClassLength`
#   offence; its 570 lines are overwhelmingly documentation. Three spec files
#   would tear apart things that share everything.
#
# So the size reflects a subject with four verbs times several git states each,
# which is inherent. What WAS removable has been removed: rebuilding the seed
# repo per example cost five git subprocesses for a byte-identical directory,
# and copying it instead took this file from 1517 git spawns to 1162.
RSpec.describe Lain::Isolation::Worktree::Handback, :seam do
  subject(:handback) { described_class.new(repo_root: @repo_root, base: no_target, journal:) }

  around do |example|
    Dir.mktmpdir("lain-repo") do |repo|
      Dir.mktmpdir("lain-worktrees") do |worktrees|
        @repo_root = File.realpath(repo)
        @root = File.realpath(worktrees)
        init_repo(@repo_root)
        example.run
      end
    end
  end

  let(:journal) { [] }
  # The opt-out from a working-branch target, spelled at every call site that takes it.
  let(:no_target) { Lain::Isolation::WorkingBranch::NONE }
  let(:backend) do
    Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @root,
                                  base: Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo_root))
  end

  # Copied, not rebuilt: five git subprocesses per example for a directory that
  # is identical every time (see {SeedRepo}).
  def init_repo(dir) = FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", dir)

  # A method, not a constant: a constant assigned inside a top-level
  # `RSpec.describe do ... end` is lexically scoped to Object, so a second
  # spec file spelling the same name silently clobbers this one -- the trap
  # CLAUDE.md records for `Data.define` blocks, in a new costume.
  def seed_files = { "README" => "seed\n" }

  # The spec's OWN git calls scrub the git-context env too, so building and
  # inspecting the throwaway repo is hermetic under an ambient GIT_*-polluted
  # env (a pre-commit hook) exactly as the subject is -- reusing the pinned
  # scrub set rather than a parallel copy.
  def run_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def try_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command
    shell
  end

  def commit_in(dir, contents, message, file: "README")
    File.write(File.join(dir, file), contents)
    run_git(dir, "add", file)
    run_git(dir, "commit", "-q", "-m", message)
    head_commit(dir)
  end

  # Fails ONE git subcommand without running it, so a failure git will not
  # produce on demand (a broken `commit`, a broken `merge --abort`) still gets
  # pinned. Everything else runs for real.
  def factory_failing(subcommand)
    real = Mixlib::ShellOut.public_method(:new)
    broken = Struct.new(:stdout, :stderr, :exitstatus) do
      def run_command = self
    end
    lambda do |*args, **kwargs|
      args.include?(subcommand) ? broken.new("", "forced failure", 1) : real.call(*args, **kwargs)
    end
  end

  # Fails ONE git subcommand by RAISING rather than exiting nonzero -- what an
  # exhausted fd table, a killed spawn or a Ctrl-C mid-call actually looks like.
  # `factory_failing` above covers the other half (git ran and refused).
  def factory_raising(subcommand, error = Errno::EMFILE)
    real = Mixlib::ShellOut.public_method(:new)
    lambda do |*args, **kwargs|
      raise(error, "git #{subcommand}") if args.include?(subcommand)

      real.call(*args, **kwargs)
    end
  end

  def head_commit(dir) = run_git(dir, "rev-parse", "HEAD").strip

  def registered_worktrees = run_git(@repo_root, "worktree", "list", "--porcelain")

  def head_refs = run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/heads").split("\n")

  def reachable_from_head?(commit)
    try_git(@repo_root, "merge-base", "--is-ancestor", commit, "HEAD").exitstatus.zero?
  end

  def ref_target(ref) = try_git(@repo_root, "rev-parse", "--verify", "--quiet", ref)

  def worker_refs = run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/lain").split("\n")

  # The ref an id anchors under, asked of the object that decides it rather than
  # reconstructed here -- a parallel copy of the slug-plus-fingerprint rule would
  # drift and the specs that depend on it would go quietly green.
  def worker_ref(worker_id) = described_class::Naming.new(worker_id).ref

  def merging? = File.exist?(File.join(@repo_root, ".git", "MERGE_HEAD"))

  describe "a worker's commit is preserved as a ref" do
    it "makes the commit reachable from a lain worker ref outside refs/heads" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(head_refs).not_to include(a_string_including("worker-1"))
    ensure
      lease&.release
    end

    # The ref lives outside refs/heads/ precisely so this cannot happen. A
    # DECLINED handback is the case that proves it: the commit is anchored and
    # the parent never moved, so a successor that saw it could only have seen it
    # through a leaked branch.
    it "leaves no branch a later acquire could check out (the crash-restart invariant)" do
      lease = backend.acquire("worker-1")
      worker_commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      File.write(File.join(@repo_root, "README"), "uncommitted parent edit\n")
      expect(handback.call(lease, worker_id: "worker-1").kind).to eq(:declined)
      lease.release

      successor = backend.acquire("worker-1")

      expect(head_refs).to eq(["refs/heads/#{run_git(@repo_root, "branch", "--show-current").strip}"])
      expect(head_commit(successor.worker_env.cwd)).not_to eq(worker_commit)
      expect(head_commit(successor.worker_env.cwd)).to eq(head_commit(@repo_root))
    ensure
      successor&.release
    end
  end

  describe "a clean parent receives the merge" do
    it "merges the commit into the parent checkout's head" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(outcome.parent_state).to eq(:merged)
      expect(reachable_from_head?(commit)).to be(true)
    ensure
      lease&.release
    end
  end

  describe "lain's merge strategy" do
    it "says a worker ahead of the parent fast-forwarded it, carrying the landed commit's full SHA" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.fast_forward).to be(true)
      expect(outcome.sha).to eq(commit).and match(/\A\h{40}\z/)
      expect(head_commit(@repo_root)).to eq(commit)
      expect(journal.last.to_h).to include(strategy: "conflict_style=zdiff3 diff_algorithm=histogram",
                                           fast_forward: true, sha: commit)
    ensure
      lease&.release
    end

    # Measured, never assumed: a parent that moved on without overlap takes a
    # real merge commit, and that commit is what landed.
    it "says a real merge did not fast-forward, carrying the merge commit's SHA" do
      lease = backend.acquire("worker-1")
      worker = commit_in(lease.worker_env.cwd, "worker\n", "worker work", file: "WORKER")
      commit_in(@repo_root, "parent\n", "parent work", file: "PARENT")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(outcome.fast_forward).to be(false)
      expect(outcome.sha).to eq(head_commit(@repo_root))
      expect(outcome.sha).not_to eq(worker)
      expect(reachable_from_head?(worker)).to be(true)
    ensure
      lease&.release
    end

    # The repository's own config asks for the two-sided style, and lain's
    # `-c` override is what puts the merge base back in the markers.
    it "leaves conflict markers carrying the merge base, whatever the ambient conflict style" do
      run_git(@repo_root, "config", "merge.conflictStyle", "merge")
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")

      expect(handback.call(lease, worker_id: "worker-1").kind).to eq(:conflicted)
      expect(File.read(File.join(@repo_root, "README"))).to match(/^\|\|\|\|\|\|\| .*\nseed$/)
    ensure
      lease&.release
    end

    it "merges with the strategy it was given, not a fixed one" do
      two_sided = Lain::Isolation::MergeStrategy.new(conflict_style: "merge", diff_algorithm: "myers")
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal:, strategy: two_sided)
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")

      handback.call(lease, worker_id: "worker-1")

      expect(File.read(File.join(@repo_root, "README"))).not_to include("|||||||")
      expect(journal.last.strategy).to eq("conflict_style=merge diff_algorithm=myers")
    ensure
      lease&.release
    end

    it "carries the merge commit's SHA once #continue concludes a conflict" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      conflicted = handback.call(lease, worker_id: "worker-1")
      File.write(File.join(@repo_root, "README"), "reconciled\n")

      outcome = handback.continue(conflicted.ref, worker_id: "worker-1")

      expect([outcome.kind, outcome.fast_forward, outcome.sha]).to eq([:merged, false, head_commit(@repo_root)])
    ensure
      lease&.release
    end

    it "carries no SHA when nothing landed" do
      lease = backend.acquire("worker-1")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect([outcome.sha, outcome.fast_forward]).to eq([nil, false])
    ensure
      lease&.release
    end
  end

  # A user's own git config reaches every merge lain runs in their checkout, so
  # each setting that changes what a merge DOES is overridden on the command
  # line, and whatever still slips through is caught by asking the parent,
  # afterwards, whether the worker's commit is really in it.
  describe "ambient config cannot steer the merge" do
    def current_branch = run_git(@repo_root, "branch", "--show-current").strip

    def worker_ahead(lease) = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

    def worker_diverged(lease)
      worker = commit_in(lease.worker_env.cwd, "worker\n", "worker work", file: "WORKER")
      commit_in(@repo_root, "parent\n", "parent work", file: "PARENT")
      worker
    end

    [["branch.<b>.mergeOptions", "--squash", :ahead],
     ["branch.<b>.mergeOptions", "--no-commit", :diverged],
     ["merge.ff", "only", :diverged],
     ["merge.ff", "false", :ahead],
     ["merge.verifySignatures", "true", :ahead]].each do |key, value, shape|
      it "lands the worker's commit, honestly reported, under #{key} = #{value}" do
        run_git(@repo_root, "config", key.sub("<b>", current_branch), value)
        lease = backend.acquire("worker-1")
        worker = shape == :ahead ? worker_ahead(lease) : worker_diverged(lease)

        outcome = handback.call(lease, worker_id: "worker-1")

        expect(outcome.kind).to eq(:merged)
        expect(reachable_from_head?(worker)).to be(true)
        expect([outcome.sha, outcome.fast_forward]).to eq([head_commit(@repo_root), shape == :ahead])
        expect(run_git(@repo_root, "status", "--porcelain", "--untracked-files=no")).to be_empty
        expect(merging?).to be(false)
      ensure
        lease&.release
      end
    end

    # The belt under the braces: a merge that exits 0 without landing -- a hook,
    # a setting nobody has thought of yet -- must not read as `:merged`.
    it "answers failed, naming why, when git reports success but the worker's commit is not in the parent" do
      real = Mixlib::ShellOut.public_method(:new)
      done = Struct.new(:stdout, :stderr, :exitstatus) { def run_command = self }
      pretending = lambda do |*args, **kwargs|
        args.include?("merge") ? done.new("", "", 0) : real.call(*args, **kwargs)
      end
      lease = backend.acquire("worker-1")
      worker_ahead(lease)
      parent_head = head_commit(@repo_root)

      outcome = described_class.new(repo_root: @repo_root, base: no_target, journal:, shell_out_factory: pretending)
                               .call(lease, worker_id: "worker-1")

      expect([outcome.kind, outcome.sha]).to eq([:failed, nil])
      expect(outcome.detail).to include("does not contain")
      expect(head_commit(@repo_root)).to eq(parent_head)
    ensure
      lease&.release
    end
  end

  # The chat's parent checkout is a human's. A worker cut from `feat` merges
  # into `feat` or nowhere: if the human has switched away, the work waits on
  # its ref rather than landing on whatever branch happens to be checked out.
  describe "the working branch is the only target" do
    it "must be told its target: leaving base: out is an ArgumentError, never a merge anywhere" do
      expect { described_class.new(repo_root: @repo_root, journal:) }.to raise_error(ArgumentError, /base/)
    end

    def current_branch = run_git(@repo_root, "branch", "--show-current").strip

    def on_feat
      original = current_branch
      run_git(@repo_root, "switch", "-q", "-c", "feat")
      [original, Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo_root)]
    end

    it "declines, naming both branches, once the human has switched the parent away" do
      original, feat = on_feat
      lease = backend.acquire("worker-1")
      worker = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      run_git(@repo_root, "switch", "-q", original)
      before = [head_commit(@repo_root), run_git(@repo_root, "rev-parse", "feat").strip]

      outcome = described_class.new(repo_root: @repo_root, journal:, base: feat).call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.detail).to include("feat", original)
      expect([head_commit(@repo_root), run_git(@repo_root, "rev-parse", "feat").strip]).to eq(before)
      expect(ref_target(outcome.ref).stdout.strip).to eq(worker)
    ensure
      lease&.release
    end

    it "declines a detached parent, saying it is detached" do
      _, feat = on_feat
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      run_git(@repo_root, "switch", "-q", "--detach", "HEAD")

      outcome = described_class.new(repo_root: @repo_root, journal:, base: feat).call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.detail).to include("detached", "feat")
    ensure
      lease&.release
    end

    it "merges into the working branch while the parent stands on it" do
      _, feat = on_feat
      lease = backend.acquire("worker-1")
      worker = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = described_class.new(repo_root: @repo_root, journal:, base: feat).call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(run_git(@repo_root, "rev-parse", "feat").strip).to eq(worker)
    ensure
      lease&.release
    end

    # NONE names no branch, so it enforces none: the behaviour of every caller
    # that has no working branch to give.
    it "merges into whatever the parent has checked out when built with no working branch" do
      original, = on_feat
      lease = backend.acquire("worker-1")
      worker = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      run_git(@repo_root, "switch", "-q", original)

      expect(handback.call(lease, worker_id: "worker-1").kind).to eq(:merged)
      expect(reachable_from_head?(worker)).to be(true)
    ensure
      lease&.release
    end
  end

  describe "a conflict is reported with its paths and its ref" do
    # The worker and the parent both move README off the SAME base commit, so
    # the merge cannot fast-forward and cannot auto-resolve.
    def diverge
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      lease
    end

    it "names the conflicting paths and the ref, raising nothing" do
      lease = diverge

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:conflicted)
      expect(outcome.paths).to eq(["README"])
      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
    ensure
      lease&.release
    end

    it "leaves the merge IN PROGRESS, with conflict markers a resolver can edit" do
      lease = diverge

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.parent_state).to eq(:merging)
      expect(outcome).to be_merge_in_progress
      expect(File.exist?(File.join(@repo_root, ".git", "MERGE_HEAD"))).to be(true)
      expect(File.read(File.join(@repo_root, "README"))).to include("<<<<<<<", "worker's line")
    ensure
      lease&.release
    end
  end

  describe "a dirty parent is never merged into" do
    it "declines, leaving the parent untouched and the work on the ref" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      File.write(File.join(@repo_root, "README"), "uncommitted parent edit\n")
      parent_head = head_commit(@repo_root)

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.parent_state).to eq(:untouched)
      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(head_commit(@repo_root)).to eq(parent_head)
      expect(File.read(File.join(@repo_root, "README"))).to eq("uncommitted parent edit\n")
      expect(File.exist?(File.join(@repo_root, ".git", "MERGE_HEAD"))).to be(false)
    ensure
      lease&.release
    end
  end

  describe "an unmoved worktree hands nothing back" do
    it "writes no ref, attempts no merge, and reports nothing-to-do" do
      lease = backend.acquire("worker-1")
      parent_head = head_commit(@repo_root)

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:nothing_to_do)
      expect(outcome.ref).to be_nil
      expect(worker_refs).to be_empty
      expect(head_commit(@repo_root)).to eq(parent_head)
    ensure
      lease&.release
    end

    it "reports nothing-to-do when the worker's commits are already in the parent" do
      lease = backend.acquire("worker-1")
      commit_in(@repo_root, "parent moved on\n", "parent work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:nothing_to_do)
      expect(worker_refs).to be_empty
    ensure
      lease&.release
    end
  end

  describe "handback never removes the worktree" do
    it "leaves the checkout on disk and registered with git after a merge" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      handback.call(lease, worker_id: "worker-1")

      expect(File.directory?(lease.worker_env.cwd)).to be(true)
      expect(registered_worktrees).to include(lease.worker_env.cwd)
      expect(lease).not_to be_released
    ensure
      lease&.release
    end

    it "leaves the checkout on disk and registered with git after a conflict" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")

      handback.call(lease, worker_id: "worker-1")

      expect(File.directory?(lease.worker_env.cwd)).to be(true)
      expect(registered_worktrees).to include(lease.worker_env.cwd)
    ensure
      lease&.release
    end
  end

  describe "a git failure is reported, not raised" do
    it "reports a failed ref write as an outcome, propagating nothing" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      # A ref BELOW the one we are about to write is a real git F/D conflict:
      # update-ref cannot lock the worker's ref while a child of it exists.
      run_git(@repo_root, "update-ref", "#{worker_ref("worker-1")}/child", head_commit(@repo_root))
      parent_head = head_commit(@repo_root)

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.detail).not_to be_empty
      expect(head_commit(@repo_root)).to eq(parent_head)
    ensure
      lease&.release
    end

    it "reports a raise from the git invocation itself as an outcome" do
      exploding = ->(*, **) { raise Errno::ENOENT, "git" }
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal:, shell_out_factory: exploding)
      lease = backend.acquire("worker-1")

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.detail).to include("git")
    ensure
      lease&.release
    end

    # "Say where the work is" is the whole contract, and a raise AFTER the ref
    # was written is the case where a human most needs it: the commits are safe
    # on a ref nobody was told about. The method-level rescue cannot know that --
    # it hard-codes nil -- so the answer has to come from the level that watched
    # the write happen.
    it "names the ref when the raise lands AFTER the ref was written" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal:,
                                     shell_out_factory: factory_raising("merge"))

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
      expect(outcome.detail).to include("Errno::EMFILE")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(journal.map(&:ref)).to eq([outcome.ref])
    ensure
      lease&.release
    end

    it "still answers with a nil ref when the raise lands BEFORE the write" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal:,
                                     shell_out_factory: factory_raising("update-ref"))

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:failed)
      expect(outcome.ref).to be_nil
      expect(worker_refs).to be_empty
    ensure
      lease&.release
    end
  end

  describe "an arbitrary worker_id" do
    it "slugs into a valid refname rather than trusting the caller's bytes" do
      lease = backend.acquire("arm 1/spawn..x")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "arm 1/spawn..x")

      expect(try_git(@repo_root, "check-ref-format", outcome.ref).exitstatus).to eq(0)
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
    ensure
      lease&.release
    end
  end

  describe "the journal record" do
    # The sync fields ride every handback record, at their "no sync ran"
    # values when the handback was not told of one.
    it "records one handback outcome: the worker key, the outcome, the ref, the strategy and what landed" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(journal.size).to eq(1)
      expect(journal.first.to_journal).to eq(
        "type" => "handback", "worker_key" => "worker-1",
        "outcome" => :merged, "ref" => outcome.ref,
        "strategy" => "conflict_style=zdiff3 diff_algorithm=histogram", "fast_forward" => true, "sha" => commit,
        "sync" => nil, "attempts" => [], "dirty" => false, "path" => nil, "detail" => ""
      )
    ensure
      lease&.release
    end

    it "records the outcome even when nothing was handed back" do
      lease = backend.acquire("worker-1")

      handback.call(lease, worker_id: "worker-1")

      expect(journal.map(&:outcome)).to eq([:nothing_to_do])
      expect(journal.first.ref).to be_nil
    ensure
      lease&.release
    end
  end

  # The load-bearing invariant, defended against the one caller that can reach
  # past every git guard: this object's OWN journalling. {WorkerHandoff} runs
  # `#call` inside a gathered fiber, where a raise takes out the worker's result.
  describe "journalling can never overturn an outcome" do
    it "answers with an outcome for a worker_id the telemetry guard rejects" do
      [nil, "", "   "].each do |blank|
        lease = backend.acquire("blank-#{blank.inspect}")
        commit_in(lease.worker_env.cwd, "worker #{blank.inspect}\n", "worker work")

        outcome = nil
        expect { outcome = handback.call(lease, worker_id: blank) }.not_to raise_error
        expect(outcome.kind).to eq(:merged)
        lease.release
      end
    end

    it "answers with an outcome when the journal sink itself raises" do
      sink = Object.new
      def sink.<<(_record) = raise(IOError, "journal is closed")
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal: sink)
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:merged)
    ensure
      lease&.release
    end

    it "names an unnamed worker rather than losing the record" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: nil)

      expect(outcome.worker_key).to eq("unnamed-worker")
      expect(journal.map(&:worker_key)).to eq(["unnamed-worker"])
    ensure
      lease&.release
    end
  end

  # Leaving the markers is only right if this object also owns the way
  # out: the resolver has no `bash`, so `git add` + `merge --continue` has to
  # live here or nowhere.
  describe "#continue" do
    def conflict_and_resolve
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      outcome = handback.call(lease, worker_id: "worker-1")
      # What a write_file-only resolver can do, and all it can do.
      File.write(File.join(@repo_root, "README"), "both lines, reconciled\n")
      [lease, outcome]
    end

    it "stages the resolution and concludes the merge the resolver could not" do
      lease, conflicted = conflict_and_resolve
      worker_commit = ref_target(conflicted.ref).stdout.strip

      outcome = handback.continue(conflicted.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(outcome.parent_state).to eq(:merged)
      expect(merging?).to be(false)
      expect(reachable_from_head?(worker_commit)).to be(true)
      expect(File.read(File.join(@repo_root, "README"))).to eq("both lines, reconciled\n")
      expect(run_git(@repo_root, "status", "--porcelain").strip).to be_empty
    ensure
      lease&.release
    end

    it "reports nothing-to-do when no merge is in progress, touching nothing" do
      parent_head = head_commit(@repo_root)

      outcome = handback.continue("refs/lain/worker/nobody")

      expect(outcome.kind).to eq(:nothing_to_do)
      expect(outcome.parent_state).to eq(:untouched)
      expect(head_commit(@repo_root)).to eq(parent_head)
    end

    it "reports a git failure as an outcome, saying the merge is still in progress" do
      lease, conflicted = conflict_and_resolve
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal:,
                                     shell_out_factory: factory_failing("commit"))

      outcome = nil
      expect { outcome = handback.continue(conflicted.ref, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.parent_state).to eq(:merging)
      expect(merging?).to be(true)
    ensure
      lease&.release
    end

    it "journals the outcome it concluded with" do
      lease, conflicted = conflict_and_resolve
      journal.clear

      handback.continue(conflicted.ref, worker_id: "worker-1")

      expect(journal.map(&:outcome)).to eq([:merged])
    ensure
      lease&.release
    end
  end

  # An LLM resolver has no way to check its own work, so a leftover marker block
  # would be committed into Joel's own history under the one outcome that means
  # "all fine". The false positive (a diff fixture; this very spec file) is
  # accepted deliberately: a false refuse costs one round trip and #abandon is
  # always there, a false accept costs markers in git history.
  describe "#continue refuses a resolution that is not one" do
    def conflicted
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      [lease, handback.call(lease, worker_id: "worker-1")]
    end

    # The three shapes git leaves behind, in order.
    def unresolved_text
      ["<<<<<<< HEAD", "parent's line", "=======", "worker's line", ">>>>>>> theirs", ""].join("\n")
    end

    it "reports the paths still carrying markers, committing nothing" do
      lease, conflict = conflicted
      File.write(File.join(@repo_root, "README"), unresolved_text)
      parent_head = head_commit(@repo_root)

      outcome = handback.continue(conflict.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:conflicted)
      expect(outcome.paths).to eq(["README"])
      expect(outcome.parent_state).to eq(:merging)
      expect(outcome.detail).to include("marker")
      expect(head_commit(@repo_root)).to eq(parent_head)
      expect(merging?).to be(true)
    ensure
      lease&.release
    end

    it "can be retried, and concludes once the markers are gone" do
      lease, conflict = conflicted
      File.write(File.join(@repo_root, "README"), unresolved_text)
      handback.continue(conflict.ref, worker_id: "worker-1")

      File.write(File.join(@repo_root, "README"), "reconciled\n")
      outcome = handback.continue(conflict.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(merging?).to be(false)
    ensure
      lease&.release
    end

    it "wants all three shapes in order, not any marker-shaped line" do
      lease, conflict = conflicted
      File.write(File.join(@repo_root, "README"), "<<<<<<< quoted in prose, not a conflict\n")

      expect(handback.continue(conflict.ref, worker_id: "worker-1").kind).to eq(:merged)
    ensure
      lease&.release
    end
  end

  # `git diff --name-only` applies core.quotePath, so a conflict on föö.txt
  # reports "f\303\266\303\266.txt": the resolver read_files a path that does not
  # exist and #continue dies on `pathspec did not match`, leaving the parent
  # stuck mid-merge with only #abandon as an exit.
  describe "a conflicted path git would otherwise quote" do
    ["föö.txt", "sp ace.txt", "we\nird.txt"].each do |name|
      it "names #{name.inspect} as it is on disk, and can conclude it" do
        lease = backend.acquire("worker-1")
        commit_in(@repo_root, "base\n", "base", file: name)
        run_git(lease.worker_env.cwd, "merge", "--ff-only", head_commit(@repo_root))
        commit_in(lease.worker_env.cwd, "worker's line\n", "worker work", file: name)
        commit_in(@repo_root, "parent's line\n", "parent work", file: name)

        outcome = handback.call(lease, worker_id: "worker-1")

        expect(outcome.paths).to eq([name])
        File.write(File.join(@repo_root, name), "reconciled\n")
        expect(handback.continue(outcome.ref, worker_id: "worker-1").kind).to eq(:merged)
      ensure
        lease&.release
      end
    end
  end

  # #key_for runs in the rescue handler as well as the body, so a raise there is
  # the round-1 double-fault again: the handler re-raises what it was called to
  # contain. Not reachable from a String worker_id, but the class doc promises
  # no raise "from a caller's nonsense".
  describe "a worker_id whose own #to_s is hostile" do
    let(:hostile) do
      { "raises" => Class.new { def to_s = raise("no name for you") }.new,
        "answers nil" => Class.new { def to_s = nil }.new,
        "is a BasicObject" => BasicObject.new }
    end

    it "still answers every operation with an outcome" do
      hostile.each_value do |id|
        lease = backend.acquire("hostile-#{id.__id__}")
        commit_in(lease.worker_env.cwd, "worker #{id.__id__}\n", "worker work")

        expect { handback.call(lease, worker_id: id) }.not_to raise_error
        expect { handback.anchor(lease, worker_id: id) }.not_to raise_error
        expect { handback.continue("refs/lain/worker/x", worker_id: id) }.not_to raise_error
        expect { handback.abandon("refs/lain/worker/x", worker_id: id) }.not_to raise_error
        lease.release
      end
    end

    it "names the unnameable rather than journalling a blank" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: hostile["raises"])

      expect(outcome.kind).to eq(:merged)
      expect(outcome.worker_key).to eq("unnamed-worker")
    ensure
      lease&.release
    end
  end

  describe "#abandon" do
    def conflict
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      [lease, handback.call(lease, worker_id: "worker-1")]
    end

    it "restores the parent and leaves the work on the ref" do
      lease, conflicted = conflict
      worker_commit = ref_target(conflicted.ref).stdout.strip

      outcome = handback.abandon(conflicted.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.parent_state).to eq(:untouched)
      expect(merging?).to be(false)
      expect(File.read(File.join(@repo_root, "README"))).to eq("parent's line\n")
      expect(ref_target(conflicted.ref).stdout.strip).to eq(worker_commit)
    ensure
      lease&.release
    end

    it "reports nothing-to-do when no merge is in progress" do
      expect(handback.abandon("refs/lain/worker/nobody").kind).to eq(:nothing_to_do)
    end

    it "reports a failed abort as an outcome that still says :merging" do
      lease, conflicted = conflict
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal:,
                                     shell_out_factory: factory_failing("--abort"))

      outcome = nil
      expect { outcome = handback.abandon(conflicted.ref, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.parent_state).to eq(:merging)
    ensure
      lease&.release
    end
  end

  # The ref half of #call with nothing after it, for the caller that is already
  # unwinding: the `update-ref` used to live inside #call, so an exception
  # raised anywhere in that method reclaimed a worktree whose commits no ref
  # reached. An `ensure` can afford this one -- it merges nothing, writes no
  # working-tree state, and reads the ref before writing it.
  describe "#anchor" do
    it "writes the worker's commit to its ref and merges nothing" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      parent_head = head_commit(@repo_root)

      outcome = handback.anchor(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(outcome.parent_state).to eq(:untouched)
      expect(head_commit(@repo_root)).to eq(parent_head)
      expect(reachable_from_head?(commit)).to be(false)
      expect(merging?).to be(false)
      expect(head_refs).not_to include(a_string_including("worker-1"))
    ensure
      lease&.release
    end

    it "answers nothing-to-do the second time, leaving the ref exactly where it was" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      first = handback.anchor(lease, worker_id: "worker-1")

      second = handback.anchor(lease, worker_id: "worker-1")

      expect(second.kind).to eq(:nothing_to_do)
      expect(second.ref).to eq(first.ref)
      expect(ref_target(second.ref).stdout.strip).to eq(commit)
      expect(worker_refs).to eq([first.ref])
    ensure
      lease&.release
    end

    it "writes no ref for a worktree that never moved" do
      lease = backend.acquire("worker-1")

      outcome = handback.anchor(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:nothing_to_do)
      expect(outcome.ref).to be_nil
      expect(worker_refs).to be_empty
    ensure
      lease&.release
    end

    it "writes no ref when the parent already has the worker's commits" do
      lease = backend.acquire("worker-1")
      commit_in(@repo_root, "parent moved on\n", "parent work")

      expect(handback.anchor(lease, worker_id: "worker-1").kind).to eq(:nothing_to_do)
      expect(worker_refs).to be_empty
    ensure
      lease&.release
    end

    # A dirty parent and a parent mid-merge are the two states #call refuses to
    # merge into. Anchoring is not a merge, so both still get their ref, and
    # neither working tree is touched.
    it "anchors into a dirty parent without touching its working tree" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      File.write(File.join(@repo_root, "README"), "uncommitted parent edit\n")

      outcome = handback.anchor(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(File.read(File.join(@repo_root, "README"))).to eq("uncommitted parent edit\n")
    ensure
      lease&.release
    end

    it "anchors into a parent mid-merge without disturbing that merge" do
      first = backend.acquire("worker-1")
      commit_in(first.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      handback.call(first, worker_id: "worker-1")
      second = backend.acquire("worker-2")
      commit = commit_in(second.worker_env.cwd, "second\n", "second work", file: "SECOND")

      outcome = handback.anchor(second, worker_id: "worker-2")

      expect(outcome.kind).to eq(:declined)
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(merging?).to be(true)
      expect(File.read(File.join(@repo_root, "README"))).to include("<<<<<<<")
    ensure
      first&.release
      second&.release
      run_git(@repo_root, "merge", "--abort")
    end

    # #anchor is the ref, not the handback: a later #call over the same lease
    # still owes the parent the merge, and finding its own ref already written
    # must not read as nothing-to-do.
    it "does not stop a later #call from merging the same commit" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      anchored = handback.anchor(lease, worker_id: "worker-1")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(outcome.ref).to eq(anchored.ref)
      expect(reachable_from_head?(commit)).to be(true)
    ensure
      lease&.release
    end

    it "leaves the checkout on disk and registered with git" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      handback.anchor(lease, worker_id: "worker-1")

      expect(File.directory?(lease.worker_env.cwd)).to be(true)
      expect(registered_worktrees).to include(lease.worker_env.cwd)
      expect(lease).not_to be_released
    ensure
      lease&.release
    end

    it "reports a failed ref write as an outcome, propagating nothing" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      # A ref BELOW the one we are about to write is a real git F/D conflict.
      run_git(@repo_root, "update-ref", "#{worker_ref("worker-1")}/child", head_commit(@repo_root))

      outcome = nil
      expect { outcome = handback.anchor(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.detail).not_to be_empty
    ensure
      lease&.release
    end

    it "reports a raise from the git invocation itself as an outcome" do
      exploding = ->(*, **) { raise Errno::ENOENT, "git" }
      handback = described_class.new(repo_root: @repo_root, base: no_target, journal:, shell_out_factory: exploding)
      lease = backend.acquire("worker-1")

      outcome = nil
      expect { outcome = handback.anchor(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.detail).to include("git")
    ensure
      lease&.release
    end

    it "journals what it anchored" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.anchor(lease, worker_id: "worker-1")

      expect(journal.map(&:outcome)).to eq([:declined])
      expect(journal.first.ref).to eq(outcome.ref)
    ensure
      lease&.release
    end

    # A TOTAL anchor failure is the worst thing that happens on this path: the
    # worktree is force-removed moments later and the commits become gc-able. A
    # silent Journal makes that indistinguishable from a worker that committed
    # nothing -- and the Journal is the experiment record, not a log. `Interrupt`
    # is here because it is `< Exception`: a `rescue StandardError` would let it
    # past the journalling, which is exactly how this went silent.
    [Errno::EMFILE, Interrupt].each do |error|
      it "journals a :failed anchor when git raises #{error}, rather than going silent" do
        lease = backend.acquire("worker-1")
        commit_in(lease.worker_env.cwd, "worker\n", "worker work")
        handback = described_class.new(repo_root: @repo_root, base: no_target, journal:,
                                       shell_out_factory: factory_raising("rev-parse", error))

        outcome = nil
        expect { outcome = handback.anchor(lease, worker_id: "worker-1") }.not_to raise_error

        expect(outcome.kind).to eq(:failed)
        expect(outcome.detail).to include(error.name)
        expect(journal.map(&:outcome)).to eq([:failed])
        expect(journal.first.worker_key).to eq("worker-1")
      ensure
        lease&.release
      end
    end

    # THE SEAM THIS DELIBERATELY DOES NOT CLOSE. {#anchor} takes a one-message
    # duck (`#worker_env`) and never asks whether the lease is still live:
    # requiring `#released?` would couple it to {Lease}'s lifecycle over a
    # condition only the lifecycle owner can act on. So a released lease is not
    # REFUSED, it is reported -- which is what a caller reads, and what the
    # Journal keeps. Every caller reaches this; the contract is here, not in a
    # hand-back note.
    it "answers a released lease with a failed outcome and a journal line, not a refusal" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      lease.release

      outcome = nil
      expect { outcome = handback.anchor(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.ref).to be_nil
      expect(journal.map(&:outcome)).to eq([:failed])
      expect(worker_refs).to be_empty
    end

    # `update-ref <ref> <new> <old>` is git's compare-and-swap, and `<old>` is
    # exactly the value {Checkout#target} just read ("" meaning must-not-exist).
    # Without it the read-then-write is not atomic and the loser of a race
    # silently overwrites the winner -- on a ref that is sometimes the ONLY
    # anchor a worker's commits have.
    it "refuses a ref write whose expected old value no longer holds" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      other = head_commit(@repo_root)
      ref = worker_ref("worker-1")
      real = Mixlib::ShellOut.public_method(:new)
      # A sibling writes the ref in the window between #target's read and the
      # update-ref about to be built.
      racing = lambda do |*args, **kwargs|
        run_git(@repo_root, "update-ref", ref, other) if args.include?("update-ref")
        real.call(*args, **kwargs)
      end

      outcome = described_class.new(repo_root: @repo_root, base: no_target, journal:, shell_out_factory: racing)
                               .anchor(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:failed)
      expect(ref_target(ref).stdout.strip).to eq(other)
    ensure
      lease&.release
    end

    # THE OTHER CAS BRANCH. Every other example here either writes into a ref
    # that does not exist (expected value "") or short-circuits at
    # `held == commit` before any write. The ADVANCE -- anchor at A, the worker
    # commits B, anchor again -- is the only path that hands the compare-and-swap
    # a NON-EMPTY expected value, so without this a mutant pinning that value to
    # "" is killed only by accident, somewhere else.
    it "advances the ref when the worker commits again after an anchor" do
      lease = backend.acquire("worker-1")
      first_commit = commit_in(lease.worker_env.cwd, "worker one\n", "worker work")
      first = handback.anchor(lease, worker_id: "worker-1")
      second_commit = commit_in(lease.worker_env.cwd, "worker two\n", "more worker work")

      second = handback.anchor(lease, worker_id: "worker-1")

      expect(first.kind).to eq(:declined)
      expect(second.kind).to eq(:declined)
      expect(second.ref).to eq(first.ref)
      expect(ref_target(first.ref).stdout.strip).to eq(second_commit)
      expect(second_commit).not_to eq(first_commit)
      # One entry per write, so the advance is on the record as an advance.
      expect(run_git(@repo_root, "reflog", second.ref).lines.size).to eq(2)
    ensure
      lease&.release
    end

    # Provenance next to the object, for someone holding nothing but the
    # repository. `--create-reflog` is what makes it stick: git's default
    # `core.logAllRefUpdates` covers only refs/heads, refs/remotes, refs/notes
    # and HEAD, so a bare `-m` on this namespace is accepted and dropped -- which
    # is a green-looking no-op, exactly the failure this example exists to catch.
    it "stamps the ref's own reflog, so the write is attributable from the repo alone" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.anchor(lease, worker_id: "worker-1")

      expect(run_git(@repo_root, "reflog", outcome.ref)).to include("lain handback: anchored")
      expect(run_git(@repo_root, "reflog", outcome.ref)).to include(commit[0, 7])
    ensure
      lease&.release
    end

    it "stamps a reflog on the ref #call anchors too, not only #anchor's" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(run_git(@repo_root, "reflog", outcome.ref)).to include("lain handback: anchored")
    ensure
      lease&.release
    end
  end

  # update-ref overwrites unconditionally, so on a declined or
  # conflicted handback -- where the ref is the ONLY anchor -- two ids that slug
  # alike would orphan one worker's commits.
  describe "the ref is one per worker, not one per slug" do
    it "gives two ids that slug alike two distinct refs, both still anchored" do
      first = backend.acquire("a/b")
      one = commit_in(first.worker_env.cwd, "one\n", "one")
      File.write(File.join(@repo_root, "README"), "parent is dirty\n") # so both DECLINE
      declined_one = handback.call(first, worker_id: "a/b")
      first.release

      second = backend.acquire("a-b")
      two = commit_in(second.worker_env.cwd, "two\n", "two")
      declined_two = handback.call(second, worker_id: "a-b")

      expect(declined_one.ref).not_to eq(declined_two.ref)
      expect(ref_target(declined_one.ref).stdout.strip).to eq(one)
      expect(ref_target(declined_two.ref).stdout.strip).to eq(two)
    ensure
      second&.release
    end

    # Both are NAMED unnamed-worker, which is a display decision; they are still
    # two workers, so the fingerprint is taken of the original id, not the name.
    it "gives two unnameable ids two refs rather than one they overwrite" do
      first = backend.acquire("blank")
      one = commit_in(first.worker_env.cwd, "one\n", "one")
      File.write(File.join(@repo_root, "README"), "parent is dirty\n") # so both DECLINE
      blank = handback.call(first, worker_id: "")
      first.release

      second = backend.acquire("whitespace")
      two = commit_in(second.worker_env.cwd, "two\n", "two")
      spaces = handback.call(second, worker_id: "   ")

      expect(blank.ref).not_to eq(spaces.ref)
      expect(ref_target(blank.ref).stdout.strip).to eq(one)
      expect(ref_target(spaces.ref).stdout.strip).to eq(two)
    ensure
      second&.release
    end

    it "keeps the caller's id readable in the ref it can be found by" do
      lease = backend.acquire("arm-3")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      expect(handback.call(lease, worker_id: "arm-3").ref).to start_with("refs/lain/worker/arm-3-")
    ensure
      lease&.release
    end

    # Every one of these slugged to a refname git rejects, or (for the empty id)
    # to `blake3:<hex>`, which check-ref-format rejects for the colon.
    hostile = { "empty" => "", "whitespace" => "   ", "dots" => "..", "unicode" => "ärm-あ",
                "dot-lock" => "job.lock.", "double-lock" => "w.lock.lock", "leading dot" => ".hidden",
                "long" => "x" * 500, "at-brace" => "a@{0}", "metachars" => "a; rm -rf /|$(id)" }
    hostile.each do |name, id|
      it "writes a refname git accepts for a #{name} worker_id" do
        lease = backend.acquire("hostile-#{name}")
        commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

        outcome = handback.call(lease, worker_id: id)

        expect(try_git(@repo_root, "check-ref-format", outcome.ref.to_s).exitstatus).to eq(0)
        expect(outcome.kind).not_to eq(:failed)
        expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      ensure
        lease&.release
      end
    end
  end

  # "uncommitted changes" names the wrong fix for a mid-merge parent: a
  # caller retries and a human hunts for edits that are not there.
  describe "a parent already mid-merge" do
    it "is reported as mid-merge, naming the way out, not as a dirty checkout" do
      first = backend.acquire("worker-1")
      commit_in(first.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      handback.call(first, worker_id: "worker-1")

      second = backend.acquire("worker-2")
      commit_in(second.worker_env.cwd, "second\n", "second work", file: "SECOND")
      outcome = handback.call(second, worker_id: "worker-2")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.detail).to include("mid-merge")
      expect(outcome.detail).not_to include("uncommitted changes")
      expect(merging?).to be(true)
    ensure
      first&.release
      second&.release
    end
  end

  # The only case reachable today (an untracked file the merge would
  # clobber, where no merge ever started) really is untouched -- but the claim
  # has to be measured, not assumed.
  describe "a merge that fails without conflicting" do
    it "restores the parent and says so" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "adds NEW", file: "NEW")
      File.write(File.join(@repo_root, "NEW"), "precious untracked bytes\n")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:failed)
      expect(outcome.parent_state).to eq(:untouched)
      expect(merging?).to be(false)
      expect(File.read(File.join(@repo_root, "NEW"))).to eq("precious untracked bytes\n")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
    ensure
      lease&.release
    end
  end

  describe Lain::Isolation::Worktree::Handback::Outcome do
    it "is deeply frozen, so an outcome crosses a Ractor boundary" do
      outcome = described_class.new(kind: :conflicted, worker_key: "w", ref: "refs/lain/worker/w",
                                    paths: ["a.rb"], parent_state: :merging, detail: "conflict")

      expect(outcome).to be_deeply_frozen
    end

    it "refuses a kind no caller can act on" do
      expect { described_class.new(kind: :probably_fine, worker_key: "w") }
        .to raise_error(ArgumentError, /kind must be one of/)
    end

    it "refuses a fast_forward that is not exactly true or false" do
      ["yes", nil, 1].each do |value|
        expect { described_class.new(kind: :merged, worker_key: "w", fast_forward: value) }
          .to raise_error(ArgumentError, /fast_forward/)
      end
    end

    # `:declined` now covers two things a caller acts on differently: a parent
    # that refused the merge (retry it later) and an anchor that never offered
    # one (there is nothing to retry). `detail` is prose, so the discrimination
    # is a message -- KINDS is closed, and widening it was the stop trigger.
    it "tells an anchor-only decline from a parent that refused the merge" do
      anchored = described_class.new(kind: :declined, worker_key: "w", ref: "refs/lain/worker/w",
                                     detail: Lain::Isolation::Worktree::Handback::ANCHOR_ONLY)
      refused = described_class.new(kind: :declined, worker_key: "w", ref: "refs/lain/worker/w",
                                    detail: Lain::Isolation::Worktree::Handback::DIRTY)

      expect(anchored).to be_anchor_only
      expect(refused).not_to be_anchor_only
      expect(described_class.new(kind: :merged, worker_key: "w")).not_to be_anchor_only
    end

    it "defaults to the untouched-parent, nothing-carried shape" do
      outcome = described_class.new(kind: :nothing_to_do, worker_key: "w")

      expect(outcome.ref).to be_nil
      expect(outcome.paths).to eq([])
      expect(outcome.parent_state).to eq(:untouched)
      expect(outcome.detail).to eq("")
      expect(outcome).not_to be_merge_in_progress
    end
  end

  # A continue concludes whichever merge the parent has in progress, and only
  # the ref's own commit being in the parent afterwards makes it THIS worker's.
  describe "#continue answers merged only for the ref it was asked about" do
    it "fails, saying so, when the merge it concluded does not contain that ref's commit" do
      first = backend.acquire("worker-1")
      second = backend.acquire("worker-2")
      commit_in(first.worker_env.cwd, "first\n", "first work")
      commit_in(second.worker_env.cwd, "second\n", "second work")
      commit_in(@repo_root, "parent\n", "parent work")
      expect(handback.call(first, worker_id: "worker-1").kind).to eq(:conflicted)
      File.write(File.join(@repo_root, "README"), "reconciled\n")
      other = handback.anchor(second, worker_id: "worker-2").ref

      outcome = handback.continue(other, worker_id: "worker-2")

      expect(outcome.kind).to eq(:failed)
      expect(outcome.detail).to include("does not contain")
      expect(outcome.sha).to be_nil
    ensure
      first&.release
      second&.release
    end
  end

  # A user's `rerere.autoupdate` replays and stages an old resolution, so the
  # merge exits nonzero with nothing left unmerged -- which reads as a failure
  # rather than the conflict it is.
  describe "a conflict the user's rerere remembers" do
    it "is still reported as a conflict, with its path" do
      run_git(@repo_root, "config", "rerere.enabled", "true")
      run_git(@repo_root, "config", "rerere.autoupdate", "true")
      lease = backend.acquire("worker-1")
      worker = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      parent = commit_in(@repo_root, "parent\n", "parent work")
      try_git(@repo_root, "-c", "merge.conflictStyle=zdiff3", "merge", "--no-edit", worker)
      File.write(File.join(@repo_root, "README"), "remembered resolution\n")
      run_git(@repo_root, "add", "README")
      run_git(@repo_root, "commit", "-q", "--no-edit")
      run_git(@repo_root, "reset", "-q", "--hard", parent)

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:conflicted)
      expect(outcome.paths).to eq(["README"])
    ensure
      try_git(@repo_root, "merge", "--abort")
      lease&.release
    end
  end

  describe "a dirty parent's refusal names what is in the way" do
    it "names at most ten files, and counts the rest" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      files = (1..12).map { |number| format("dirty-%02d.txt", number) }
      files.each { |file| File.write(File.join(@repo_root, file), "tracked\n") }
      run_git(@repo_root, "add", *files)
      run_git(@repo_root, "commit", "-q", "-m", "twelve tracked files")
      files.each { |file| File.write(File.join(@repo_root, file), "edited\n") }

      detail = handback.call(lease, worker_id: "worker-1").detail

      expect(detail).to include("dirty-01.txt", "dirty-10.txt", "and 2 more")
      expect(detail).not_to include("dirty-11.txt")
    ensure
      lease&.release
    end

    it "still declines, saying the files could not be listed, when git cannot list them" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      File.write(File.join(@repo_root, "README"), "uncommitted parent edit\n")
      unlisted = described_class.new(repo_root: @repo_root, base: no_target, journal:,
                                     shell_out_factory: factory_failing("diff"))

      outcome = unlisted.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.detail).to include("uncommitted changes").and include("could not be listed")
    ensure
      lease&.release
    end
  end
end
