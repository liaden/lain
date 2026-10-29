# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Operates on a THROWAWAY upstream copied from {SeedRepo}, never the lain repo.
RSpec.describe Lain::Isolation::Clone, :seam do
  subject(:backend) { described_class.new(repo_root: @upstream, root: @root, base:) }

  let(:base) { Lain::Isolation::WorkingBranch.checked_out(repo_root: @upstream) }
  let(:identity) { %w[-c user.name=w -c user.email=w@example.com] }

  around do |example|
    Dir.mktmpdir("lain-clone") do |dir|
      @upstream = File.join(File.realpath(dir), "upstream")
      # Under lain's lease container, the one tree whose records lain trusts.
      @root = File.join(Lain::Paths.new.state_home, "worktrees", Lain::Paths.new.project_hash(@upstream))
      FileUtils.mkdir_p(@upstream)
      FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", @upstream)
      example.run
    ensure
      FileUtils.rm_rf(@root) if @root
    end
  end

  def git(dir, *) = SeedRepo.git(dir, *).stdout.strip

  def try_git(dir, *)
    Lain::Shell::Out.new("git", "-C", dir, *, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command
  end

  def commit_in(dir, body = "work\n")
    File.write(File.join(dir, "README"), body)
    git(dir, *identity, "commit", "-q", "-am", "work")
    git(dir, "rev-parse", "HEAD")
  end

  def in_upstream?(commit) = Lain::Shell::Out.ok?(try_git(@upstream, "cat-file", "-e", "#{commit}^{commit}"))

  def pins = git(@upstream, "for-each-ref", "--format=%(refname) %(objectname)", "refs/lain/lease/").split("\n")
  def pin_of(path) = "refs/lain/lease/#{Lain::Paths.new.project_hash(@root)}/#{File.basename(path)}"

  def dead_pid = Process.spawn("true").tap { |pid| Process.wait(pid) }

  describe "#acquire" do
    it "cuts a clone of its own, sharing upstream's objects through alternates, detached at the base" do
      lease = backend.acquire("worker-1")
      path = lease.worker_env.cwd
      alternates = File.read(File.join(path, ".git", "objects", "info", "alternates")).strip

      expect(File.directory?(File.join(path, ".git"))).to be(true)
      expect(File.realpath(alternates)).to eq(File.realpath(File.join(@upstream, ".git", "objects")))
      expect([git(path, "rev-parse", "HEAD"), try_git(path, "symbolic-ref", "-q", "HEAD").stdout])
        .to eq([base.tip, ""])
    ensure
      lease&.release
    end

    it "keeps no branch or remote ref in the clone that upstream could prune from under it" do
      lease = backend.acquire("worker-1")

      expect(git(lease.worker_env.cwd, "for-each-ref", "--format=%(refname)")).to eq("")
    ensure
      lease&.release
    end

    it "registers no worktree in upstream" do
      lease = backend.acquire("worker-1")

      expect(git(@upstream, "worktree", "list", "--porcelain")).not_to include(lease.worker_env.cwd)
    ensure
      lease&.release
    end

    it "runs upstream's hooks, as git resolves them for upstream, from the clone's config" do
      hooks = File.join(@upstream, "custom-hooks")
      FileUtils.mkdir_p(hooks)
      git(@upstream, "config", "core.hooksPath", hooks)
      File.write(File.join(hooks, "pre-commit"), "#!/bin/sh\necho upstream-hook-ran >&2\nexit 1\n")
      File.chmod(0o755, File.join(hooks, "pre-commit"))
      lease = backend.acquire("worker-1")
      path = lease.worker_env.cwd
      File.write(File.join(path, "README"), "work\n")
      committed = try_git(path, *identity, "commit", "-q", "-am", "work")

      expect(git(path, "config", "--local", "core.hooksPath")).to eq(hooks)
      expect([committed.exitstatus, committed.stderr]).to match([1, /upstream-hook-ran/])
    ensure
      lease&.release
    end

    it "pins the base in upstream while leased, so an upstream prune cannot take objects the clone reads" do
      lease = backend.acquire("worker-1")

      expect(pins).to eq(["#{pin_of(lease.worker_env.cwd)} #{base.tip}"])
    ensure
      lease&.release
    end

    it "holds a lock outside the clone naming this process, where a sandboxed call cannot reach it" do
      lease = backend.acquire("worker-1")
      path = lease.worker_env.cwd
      locked = Dir.glob(File.join(@root, ".*")).grep(/#{File.basename(path)}\.locked\z/)

      expect(locked.map { File.read(_1).chomp })
        .to match([/\Alain-lease pid=#{Process.pid} start=\S+ host=#{Regexp.escape(Socket.gethostname)}\z/])
      expect(locked.none? { Lain::Landing.under?(_1, path) }).to be(true)
    ensure
      lease&.release
    end

    it "refuses a clone it cannot cut, naming the clone rather than a worktree" do
      FileUtils.mkdir_p(foreign = File.join(@root, Lain::Paths.new.project_hash("worker-1")))
      File.write(File.join(foreign, "x"), "x")

      message = begin
        backend.acquire("worker-1")
      rescue Lain::Isolation::Worktree::Refused => e
        e.message
      end

      expect(message).to match(/worker-1: clone lease add #{Regexp.escape(foreign)} failed/)
      expect(message).not_to include("git worktree")
    end

    it "refuses a leftover whose lock names a live process, naming the worker" do
      held = backend.acquire("worker-1")
      restarted = described_class.new(repo_root: @upstream, root: @root, base:)

      expect { restarted.acquire("worker-1") }
        .to raise_error(Lain::Isolation::Worktree::Refused,
                        /worker-1: clone lease at .* is held: .*live process #{Process.pid}/)
    ensure
      held&.release
    end

    it "re-leases a worker whose clone was removed by hand while a dead process's lock stayed" do
      crashed = described_class.new(repo_root: @upstream, root: @root, base:,
                                    process_table: Lain::Isolation::LeaseLock::ProcessTable.new(pid: dead_pid))
      FileUtils.rm_rf(crashed.acquire("worker-1").worker_env.cwd)

      lease = backend.acquire("worker-1")

      expect([File.directory?(lease.worker_env.cwd), pins.size]).to eq([true, 1])
    ensure
      lease&.release
    end

    it "still guards a clone moved aside: a commondir planted there stops lain's git" do
      crashed = described_class.new(repo_root: @upstream, root: @root, base:,
                                    process_table: Lain::Isolation::LeaseLock::ProcessTable.new(pid: dead_pid))
      crashed.acquire("worker-1")
      lease = backend.acquire("worker-1")
      aside = Dir.glob(File.join(@root, Lain::Isolation::Worktree::RETAINED, "*")).sole
      File.write(File.join(aside, ".git", "commondir"), "../evil\n")

      expect(Lain::Isolation::Checkout.of(aside).run("status").stderr).to include("commondir")
    ensure
      lease&.release
    end

    it "moves a crashed leftover aside, retained, with its lock and its pin" do
      crashed = described_class.new(repo_root: @upstream, root: @root, base:,
                                    process_table: Lain::Isolation::LeaseLock::ProcessTable.new(pid: dead_pid))
      first = crashed.acquire("worker-1").worker_env.cwd
      File.write(File.join(first, "scratch.txt"), "left\n")

      lease = backend.acquire("worker-1")
      aside = Dir.glob(File.join(@root, Lain::Isolation::Worktree::RETAINED, "*")).sole

      expect([lease.worker_env.cwd, File.read(File.join(aside, "scratch.txt"))]).to eq([first, "left\n"])
      expect(pins.map { _1.split.first })
        .to contain_exactly(pin_of(first), pin_of(aside))
    ensure
      lease&.release
    end
  end

  describe "a lease's work, folded back" do
    it "stays out of upstream until the handback fetches it, then lands on the worker's ref" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd)
      before = in_upstream?(commit)

      outcome = Lain::Isolation::Worktree::Handback.new(repo_root: @upstream, base: Lain::Isolation::WorkingBranch::NONE)
                                                   .anchor(lease, worker_id: "worker-1")

      expect([before, outcome.kind, git(@upstream, "rev-parse", outcome.ref)]).to eq([false, :declined, commit])
    ensure
      lease&.release
    end

    it "anchors a clean lease's unreached commit in upstream on release, then removes the clone and its pin" do
      lease = backend.acquire("worker-1")
      path = lease.worker_env.cwd
      commit = commit_in(path)
      lease.release

      anchors = git(@upstream, "for-each-ref", "--format=%(objectname)", "refs/lain/worker/").split("\n")

      expect([File.exist?(path), pins, anchors]).to eq([false, [], [commit]])
      expect(backend.retained?(path)).to be(false)
    end

    it "keeps a clone whose git dir holds a planted commondir even when told to discard it" do
      lease = backend.acquire("worker-1")
      path = lease.worker_env.cwd
      File.write(File.join(path, ".git", "commondir"), "../evil\n")
      lease.release(discard: true)

      expect([backend.retained?(path), File.directory?(path), pins.size]).to eq([true, true, 1])
    end

    it "retains a clone holding uncommitted work, under a retention lock, its pin kept" do
      lease = backend.acquire("worker-1")
      path = lease.worker_env.cwd
      File.write(File.join(path, "new.txt"), "written\n")
      lease.release

      locked = Dir.glob(File.join(@root, ".*")).grep(/#{File.basename(path)}\.locked\z/).map { File.read(_1).chomp }

      expect([backend.retained?(path), File.read(File.join(path, "new.txt"))]).to eq([true, "written\n"])
      expect([locked, pins.size]).to match([[/\Alain-retained since=/], 1])
    end
  end
end
