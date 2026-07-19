# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# Operates on a THROWAWAY repo it creates itself (git init in a mktmpdir), never
# the lain repo it runs in. git is always present, so this stays in the default
# suite.
RSpec.describe Lain::Isolation::Worktree do
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

  subject(:backend) { described_class.new(repo_root: @repo_root, root: @root) }

  # The expected per-worker path, keyed the same way the backend keys it.
  def worktree_path(worker_id)
    File.join(@root, Lain::Paths.new.project_hash(worker_id.to_s))
  end

  def init_repo(dir)
    run_git(dir, "init", "-q")
    run_git(dir, "config", "user.email", "test@example.com")
    run_git(dir, "config", "user.name", "Test")
    File.write(File.join(dir, "README"), "seed\n")
    run_git(dir, "add", "README")
    run_git(dir, "commit", "-q", "-m", "seed")
  end

  # The spec's OWN git calls scrub the git-context env too, so building and
  # inspecting the throwaway repo is hermetic under an ambient GIT_*-polluted
  # env (a pre-commit hook) exactly as the backend is -- reusing the backend's
  # pinned scrub set rather than a parallel copy.
  def run_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def registered_worktrees = run_git(@repo_root, "worktree", "list", "--porcelain")

  def branches(dir)
    run_git(dir, "branch", "--list").split("\n").map { |line| line.delete_prefix("* ").strip }.sort
  end

  def head_commit(dir) = run_git(dir, "rev-parse", "HEAD").strip

  describe "#acquire" do
    it "creates a git worktree at the per-worker path and points the lease there" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")

      expect(File.directory?(path)).to be(true)
      expect(File.exist?(File.join(path, ".git"))).to be(true)
      expect(registered_worktrees).to include(path)
      expect(lease.worker_env.cwd).to eq(path)
    ensure
      lease&.release
    end

    it "refuses LOUDLY when git worktree add fails, never handing back a lease" do
      Dir.mktmpdir("not-a-repo") do |bogus|
        backend = described_class.new(repo_root: File.realpath(bogus), root: @root)
        expect { backend.acquire("worker-1") }.to raise_error(described_class::Refused)
      end
    end

    it "reaps a leftover worktree at the target path rather than leaking or failing" do
      backend.acquire("worker-1")
      path = worktree_path("worker-1")
      expect(registered_worktrees).to include(path)

      # A crash kills the process, taking the in-memory lease-set with it; the
      # restart is a FRESH backend that finds the on-disk leftover and reaps it.
      restarted = described_class.new(repo_root: @repo_root, root: @root)
      lease = restarted.acquire("worker-1")

      expect(File.directory?(path)).to be(true)
      expect(lease.worker_env.cwd).to eq(path)
    ensure
      lease&.release
    end
  end

  describe "detached checkout (no branch leak, no stale-branch reuse)" do
    it "leaves no new branch behind across a full acquire/release cycle" do
      before = branches(@repo_root)

      lease = backend.acquire("worker-1")
      lease.release

      expect(branches(@repo_root)).to eq(before)
    end

    it "re-acquires at the repo's current commit, not a crashed worker's committed tip" do
      crashed = backend.acquire("worker-1")
      path = crashed.worker_env.cwd
      File.write(File.join(path, "leaked_work.txt"), "worker committed this\n")
      run_git(path, "add", "leaked_work.txt")
      run_git(path, "commit", "-q", "-m", "worker work")
      # Simulate a crash: the process (and its lease-set) dies, leaving the
      # worktree -- and, on the buggy bare-add path, its auto-created branch tip
      # -- behind. The restart is a fresh backend re-acquiring the same id.
      restarted = described_class.new(repo_root: @repo_root, root: @root)

      lease = restarted.acquire("worker-1")
      fresh = lease.worker_env.cwd

      expect(head_commit(fresh)).to eq(head_commit(@repo_root))
      expect(File.exist?(File.join(fresh, "leaked_work.txt"))).to be(false)
    ensure
      lease&.release
    end
  end

  describe "under a GIT_*-polluted environment (e.g. launched from a git hook)" do
    # pre-commit exports GIT_DIR/GIT_INDEX_FILE pointing at the HOOK's repo; a
    # shelled git that inherits them resolves index/dir against the wrong repo
    # ("Not a directory", exit 128). GIT_INDEX_FILE below sits under a real FILE
    # (README), reproducing that exact ENOTDIR.
    around do |example|
      polluted = {
        "GIT_DIR" => File.join(@repo_root, "nonexistent.git"),
        "GIT_INDEX_FILE" => File.join(@repo_root, "README", "index"),
        "GIT_WORK_TREE" => @repo_root
      }
      saved = ENV.to_h.slice(*polluted.keys)
      ENV.update(polluted)
      example.run
    ensure
      polluted.each_key { |key| ENV.delete(key) }
      ENV.update(saved)
    end

    it "scrubs git-context vars so its git calls target the leased repo, not the hook's" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")

      expect(File.directory?(path)).to be(true)
      lease.release
      expect(File.exist?(path)).to be(false)
    end
  end

  describe "concurrent acquire of the same worker_id" do
    it "leases the path to exactly one caller and refuses the other LOUDLY" do
      results = Queue.new
      threads = 2.times.map do
        Thread.new do
          results << [:ok, backend.acquire("dup")]
        rescue described_class::Refused => e
          results << [:refused, e]
        end
      end
      threads.each(&:join)

      outcomes = Array.new(results.size) { results.pop }
      leases = outcomes.filter_map { |kind, value| value if kind == :ok }
      kinds = outcomes.map(&:first)

      expect(kinds.count(:ok)).to eq(1)
      expect(kinds.count(:refused)).to eq(1)
    ensure
      leases&.each(&:release)
    end
  end

  describe Lain::Isolation::Worktree::Refused do
    let(:shell) { Struct.new(:exitstatus, :stderr).new(1, "boom") }

    it "names the add operation when the add path raises it" do
      expect(described_class.from_git("add", "/some/path", shell).message)
        .to include("git worktree add /some/path")
    end

    it "names the remove operation when the release path raises it" do
      expect(described_class.from_git("remove", "/some/path", shell).message)
        .to include("git worktree remove /some/path")
    end
  end

  describe "releasing the lease" do
    it "removes the worktree from disk and from git's registration" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")

      lease.release

      expect(File.exist?(path)).to be(false)
      expect(registered_worktrees).not_to include(path)
    end

    it "removes a worktree with uncommitted changes anyway (never leaks silently)" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")
      File.write(File.join(path, "dirty.txt"), "uncommitted\n")
      File.write(File.join(path, "README"), "modified\n")

      expect { lease.release }.not_to raise_error
      expect(File.exist?(path)).to be(false)
    end

    it "is idempotent-loud: the worktree is removed once, a second release is false" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")

      expect(lease.release).to be(true)
      expect(lease.release).to be(false)
      expect(File.exist?(path)).to be(false)
    end
  end
end
