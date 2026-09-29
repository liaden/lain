# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# Operates on a THROWAWAY repo it creates itself (git init in a mktmpdir), never
# the lain repo it runs in. git is always present, so this stays in the default
# suite.
RSpec.describe Lain::Isolation::Worktree, :seam do
  subject(:backend) { described_class.new(repo_root: @repo_root, root: @root, base:) }

  let(:base) { Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo_root) }

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

  # The expected per-worker path, keyed the same way the backend keys it.
  def worktree_path(worker_id)
    File.join(@root, Lain::Paths.new.project_hash(worker_id.to_s))
  end

  # Copied, not rebuilt: five git subprocesses per example for a directory that
  # is identical every time (see {SeedRepo}). A method, not a constant --
  # a constant inside a top-level `RSpec.describe do ... end` lands on Object,
  # where a second spec file spelling the same name silently clobbers it.
  def init_repo(dir) = FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", dir)

  def seed_files = { "README" => "seed\n" }

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

  # Answers the shell rather than raising, for a git command the example
  # expects may be refused.
  def try_git(dir, *args)
    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command
  end

  # The ref a checkout has out, or "" when its HEAD is detached.
  def branch_of(dir) = try_git(dir, "symbolic-ref", "--quiet", "HEAD").stdout.strip

  # What an issue actor does to a leased checkout before its worker writes.
  def switch_onto_issue_branch(dir) = run_git(dir, "switch", "-q", "-c", "lain/issue/e/i")

  # Runs `act` once, just before the backend's first `update-ref` of HEAD:
  # the checkout's HEAD moving between the backend reading it and detaching it.
  def moving_head_first(&act)
    pending = [act]
    lambda do |*argv, **kwargs|
      pending.shift&.call if argv.include?("--no-deref")
      Lain::Shell::Out.new(*argv, **kwargs)
    end
  end

  def commit_file(dir, file)
    File.write(File.join(dir, file), "#{file}\n")
    run_git(dir, "add", file)
    run_git(dir, "commit", "-q", "-m", file)
    head_commit(dir)
  end

  def lock_line(path)
    registered_worktrees.split("\n\n").find { |entry| entry.include?("worktree #{path}\n") }
                        .to_s[/^locked.*$/].to_s
  end

  # A pid that existed a moment ago and has exited: what a crashed lain leaves
  # in its lease lock.
  def dead_pid = Process.spawn("true").tap { |pid| Process.wait(pid) }

  # A backend whose leases name a process that is already gone, so a fresh
  # backend in this same process reads them as a crash's leftovers.
  def crashed_backend
    described_class.new(repo_root: @repo_root, root: @root, base:,
                        process_table: Lain::Isolation::LeaseLock::ProcessTable.new(pid: dead_pid))
  end

  describe "the lease lock" do
    it "locks every checkout it adds, naming this process, its start time and this host" do
      lease = backend.acquire("worker-1")

      expect(lock_line(worktree_path("worker-1")))
        .to match(/\Alocked lain-lease pid=#{Process.pid} start=\S+ host=#{Regexp.escape(Socket.gethostname)}\z/)
    ensure
      lease&.release
    end

    it "takes the lock in the add itself, so no moment exists without it" do
      calls = []
      real = Lain::Shell::Out.public_method(:new)
      recording = lambda do |*argv, **kwargs|
        calls << argv
        real.call(*argv, **kwargs)
      end

      lease = described_class.new(repo_root: @repo_root, root: @root, base:, shell_out_factory: recording)
                             .acquire("worker-1")
      add = calls.find { |argv| argv.include?("add") }
      reason = lock_line(worktree_path("worker-1")).delete_prefix("locked ")

      expect(add[add.index("add")..])
        .to eq(["add", "--lock", "--reason", reason, "--detach", worktree_path("worker-1"), base.tip])
    ensure
      lease&.release
    end

    it "clears a crash's leftover under worktree.useRelativePaths, where git records relative paths" do
      run_git(@repo_root, "config", "worktree.useRelativePaths", "true")
      crashed_backend.acquire("worker-1")

      lease = described_class.new(repo_root: @repo_root, root: @root, base:).acquire("worker-1")

      expect(lease.worker_env.cwd).to eq(worktree_path("worker-1"))
    ensure
      lease&.release
    end

    it "refuses a leftover beside an interrupted lock claim, naming it" do
      crashed_backend.acquire("worker-1")
      path = worktree_path("worker-1")
      admin = File.expand_path(File.read(File.join(path, ".git"))[/\Agitdir: (.+)$/, 1], path)
      File.rename(File.join(admin, "locked"), File.join(admin, "locked.lain-claim-deadbeef0000"))
      restarted = described_class.new(repo_root: @repo_root, root: @root, base:)

      expect { restarted.acquire("worker-1") }.to raise_error(described_class::Refused, /interrupted lock claim/)
      expect(File.directory?(path)).to be(true)
    end

    it "refuses to reap a leftover whose lock names a live process" do
      held = backend.acquire("worker-1")
      restarted = described_class.new(repo_root: @repo_root, root: @root, base:)

      expect { restarted.acquire("worker-1") }.to raise_error(described_class::Refused, /live process #{Process.pid}/)
      expect(File.directory?(held.worker_env.cwd)).to be(true)
    ensure
      held&.release
    end

    # The path is a hash of the worker id, so a refusal naming only the path
    # leaves a reader unable to say whose lease it was.
    it "names the worker whose lease was refused" do
      held = backend.acquire("worker-1")
      restarted = described_class.new(repo_root: @repo_root, root: @root, base:)

      expect { restarted.acquire("worker-1") }.to raise_error(described_class::Refused, /worker-1/)
    ensure
      held&.release
    end
  end

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
        backend = described_class.new(repo_root: File.realpath(bogus), root: @root, base:)
        expect { backend.acquire("worker-1") }.to raise_error(described_class::Refused)
      end
    end

    # A crash kills the process, taking the in-memory lease-set with it; the
    # restart is a FRESH backend that finds the on-disk leftover, whose lock
    # names a dead process, and moves it out of the way.
    it "moves a crashed leftover aside, retained, rather than leaking or failing" do
      crashed_backend.acquire("worker-1")
      path = worktree_path("worker-1")

      lease = described_class.new(repo_root: @repo_root, root: @root, base:).acquire("worker-1")
      aside = registered_worktrees.scan(/^worktree (.*)$/).flatten.find do |dir|
        dir.start_with?(File.join(@root, "retained"))
      end

      expect(lease.worker_env.cwd).to eq(path)
      expect(File.directory?(aside)).to be(true)
      expect(lock_line(aside)).to match(/\Alocked lain-retained since=\S+\z/)
    ensure
      lease&.release
    end

    # A crash's checkout has been nobody's since it was cut, not since the
    # restart found it, so moving it aside must not hand it a fresh week.
    it "stamps a crashed leftover moved aside as retained from when it was cut, not from the move" do
      crashed = crashed_backend.acquire("worker-1").worker_env.cwd
      cut = Time.utc(2026, 9, 1, 12)
      File.utime(cut, cut, File.join(crashed, ".git"))
      restarted = described_class.new(repo_root: @repo_root, root: @root, base:, clock: -> { Time.utc(2026, 9, 14) })

      lease = restarted.acquire("worker-1")
      aside = Dir.glob(File.join(@root, "retained", "*")).first

      expect(lock_line(aside)).to eq("locked lain-retained since=2026-09-01T12:00:00Z")
    ensure
      lease&.release
    end

    # The retry of a crashed issue switches its fresh checkout onto the same
    # branch, which git refuses while the leftover still has it out.
    it "detaches a crashed leftover moved aside from the branch it held, so the retry can switch onto it" do
      crashed = crashed_backend.acquire("worker-1").worker_env.cwd
      switch_onto_issue_branch(crashed)
      File.write(File.join(crashed, "work.txt"), "uncommitted\n")
      tip = head_commit(crashed)

      lease = described_class.new(repo_root: @repo_root, root: @root, base:).acquire("worker-1")
      aside = Dir.glob(File.join(@root, "retained", "*")).first

      expect([branch_of(aside), head_commit(aside), File.read(File.join(aside, "work.txt"))])
        .to eq(["", tip, "uncommitted\n"])
      expect(try_git(lease.worker_env.cwd, "switch", "-q", "lain/issue/e/i").exitstatus).to eq(0)
    ensure
      lease&.release
    end

    it "refuses, rather than move HEAD back, when the leftover's branch moved after it was read" do
      crashed = crashed_backend.acquire("worker-1").worker_env.cwd
      switch_onto_issue_branch(crashed)
      moved = nil
      factory = moving_head_first { moved = commit_file(crashed, "late.txt") }
      restarted = described_class.new(repo_root: @repo_root, root: @root, base:, shell_out_factory: factory)

      expect { restarted.acquire("worker-1") }.to raise_error(described_class::Refused, /could not be detached/)
      expect([branch_of(crashed), head_commit(crashed), run_git(crashed, "status", "--porcelain")])
        .to eq(["refs/heads/lain/issue/e/i", moved, ""])
    end
  end

  describe "a lease cut from the working branch" do
    def commit_on(dir, message)
      File.write(File.join(dir, "README"), "#{message}\n")
      run_git(dir, "commit", "-q", "-am", message)
      head_commit(dir)
    end

    it "checks out the base's tip, not whatever HEAD is on" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")
      feat_tip = commit_on(@repo_root, "feat work")
      feat = Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo_root)
      run_git(@repo_root, "switch", "-q", "-")

      lease = described_class.new(repo_root: @repo_root, root: @root, base: feat).acquire("worker-1")

      expect(head_commit(lease.worker_env.cwd)).to eq(feat_tip)
      expect(head_commit(@repo_root)).not_to eq(feat_tip)
    ensure
      lease&.release
    end

    # The tip is read per acquire, so a second worker leased after a commit
    # lands starts from that commit.
    it "cuts a later lease from a tip that moved in between" do
      first = backend.acquire("worker-1")
      old_tip = head_commit(@repo_root)
      new_tip = commit_on(@repo_root, "landed after the first lease")

      second = backend.acquire("worker-2")

      expect([head_commit(first.worker_env.cwd), head_commit(second.worker_env.cwd)]).to eq([old_tip, new_tip])
    ensure
      first&.release
      second&.release
    end

    # git's DWIM turns a NAME given to `worktree add` into a branch checkout,
    # which is the leaked-branch bleed the detached checkout exists to stop.
    it "hands worktree add the tip's full SHA, never the branch name" do
      calls = []
      real = Lain::Shell::Out.public_method(:new)
      recording = lambda do |*argv, **kwargs|
        calls << argv
        real.call(*argv, **kwargs)
      end

      lease = described_class.new(repo_root: @repo_root, root: @root, base:, shell_out_factory: recording)
                             .acquire("worker-1")

      expect(calls.find { |argv| argv.include?("add") }.last).to eq(base.tip).and match(/\A\h{40}\z/)
    ensure
      lease&.release
    end

    it "refuses a lease from a backend built with no base, leaving nothing on disk" do
      unbased = described_class.new(repo_root: @repo_root, root: @root)

      expect { unbased.acquire("worker-1") }
        .to raise_error(Lain::Isolation::WorkingBranch::Refused, /no working branch/)
      expect(Dir.children(@root)).to be_empty
      expect(registered_worktrees.lines.grep(/^worktree /).size).to eq(1)
    end

    it "answers the base it cuts from, so a caller holding the backend can name the working branch" do
      expect(backend.base).to equal(base)
    end

    # A handback merges into this, and a caller re-deriving it independently
    # (a separate `rev-parse --show-toplevel`) can disagree with the backend
    # under GIT_CEILING_DIRECTORIES -- the repository this backend was
    # constructed with is the one honest answer.
    it "answers the repository it was constructed with, as a caller's one authority for where to merge back" do
      expect(backend.repo_root).to eq(@repo_root)
    end

    it "names its checkout's path, the commit it was cut from, and the branch" do
      lease = backend.acquire("worker-1")

      expect(lease.origin.to_h).to eq(path: worktree_path("worker-1"), base: base.tip, branch: base.name)
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

    it "re-acquires at the base's tip, not a crashed worker's committed tip, and keeps that commit aside" do
      crashed = crashed_backend.acquire("worker-1")
      path = crashed.worker_env.cwd
      File.write(File.join(path, "leaked_work.txt"), "worker committed this\n")
      run_git(path, "add", "leaked_work.txt")
      run_git(path, "commit", "-q", "-m", "worker work")
      # Simulate a crash: the process (and its lease-set) dies, leaving the
      # worktree -- and, on the buggy bare-add path, its auto-created branch tip
      # -- behind. The restart is a fresh backend re-acquiring the same id.
      restarted = described_class.new(repo_root: @repo_root, root: @root, base:)

      lease = restarted.acquire("worker-1")
      fresh = lease.worker_env.cwd

      expect(head_commit(fresh)).to eq(base.tip)
      expect(File.exist?(File.join(fresh, "leaked_work.txt"))).to be(false)
      expect(Dir.glob(File.join(@root, "retained", "*", "leaked_work.txt")).size).to eq(1)
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
      threads = Array.new(2) do
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

    it "unlocks a clean checkout and answers that it was not retained" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")

      lease.release

      expect([File.exist?(path), backend.retained?(path)]).to eq([false, false])
    end

    # A worker's uncommitted work is never optional: release keeps the tree
    # on disk under a retention lock, and the reaper ages it from then.
    it "retains a checkout with uncommitted changes, re-locked as retained, and says so" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")
      File.write(File.join(path, "README"), "modified\n")

      expect(lease.release).to be(true)
      expect(File.read(File.join(path, "README"))).to eq("modified\n")
      expect(lock_line(path)).to match(/\Alocked lain-retained since=\d{4}-\d\d-\d\dT[\d:]+Z\z/)
      expect(backend.retained?(path)).to be(true)
    end

    # A retained tree holds a commit, not the branch name, so the issue's
    # retry can check the branch out elsewhere; the files stay exactly as the
    # worker left them.
    it "detaches a retained checkout at its branch's commit, so a new checkout can switch onto the branch" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")
      switch_onto_issue_branch(path)
      File.write(File.join(path, "work.txt"), "uncommitted\n")
      tip = head_commit(path)

      lease.release
      retry_lease = backend.acquire("worker-2")

      expect([branch_of(path), head_commit(path), File.read(File.join(path, "work.txt"))])
        .to eq(["", tip, "uncommitted\n"])
      expect(try_git(retry_lease.worker_env.cwd, "switch", "-q", "lain/issue/e/i").exitstatus).to eq(0)
      expect(run_git(@repo_root, "for-each-ref", "refs/lain/worker/")).to eq("")
    ensure
      retry_lease&.release
    end

    it "leaves the branch checked out, rather than move HEAD back, when it moved after the checkout was read" do
      moved = nil
      path = worktree_path("worker-1")
      factory = moving_head_first { moved = commit_file(path, "late.txt") }
      lease = described_class.new(repo_root: @repo_root, root: @root, base:, shell_out_factory: factory)
                             .acquire("worker-1")
      switch_onto_issue_branch(path)
      File.write(File.join(path, "work.txt"), "uncommitted\n")

      lease.release

      expect([branch_of(path), head_commit(path), run_git(path, "status", "--porcelain")])
        .to eq(["refs/heads/lain/issue/e/i", moved, "?? work.txt\n"])
    end

    it "retains a checkout whose state git cannot read" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")
      File.write(File.join(path, "untracked.txt"), "worker output\n")
      File.write(run_git(path, "rev-parse", "--path-format=absolute", "--git-path", "index").strip, "garbage")

      lease.release

      expect([File.exist?(File.join(path, "untracked.txt")), backend.retained?(path)]).to eq([true, true])
    end

    it "anchors a clean checkout's commit that nothing else reaches before removing it" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")
      File.write(File.join(path, "c.txt"), "c\n")
      run_git(path, "add", "c.txt")
      run_git(path, "commit", "-q", "-m", "c")
      head = head_commit(path)

      lease.release

      anchored = run_git(@repo_root, "for-each-ref", "--format=%(objectname)", "refs/lain/worker/").split("\n")
      expect([File.exist?(path), backend.retained?(path), anchored]).to eq([false, false, [head]])
    end

    it "writes no anchor for a clean checkout a branch already reaches" do
      backend.acquire("worker-1").release

      expect(run_git(@repo_root, "for-each-ref", "refs/lain/worker/")).to eq("")
    end

    it "counts an untracked file alone as uncommitted work" do
      lease = backend.acquire("worker-1")
      path = worktree_path("worker-1")
      File.write(File.join(path, "scratch.txt"), "untracked\n")

      lease.release

      expect([File.exist?(File.join(path, "scratch.txt")), backend.retained?(path)]).to eq([true, true])
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
