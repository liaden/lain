# frozen_string_literal: true

require "monitor"
require "fileutils"

module Lain
  module Isolation
    # Isolation by `git worktree`: each worker leases its own checkout of the
    # repo under a per-worker path, with the lease's cwd pointing there, and the
    # worktree is removed on release. Two workers acquired from the same repo
    # never share a working tree, so a file a worker writes is invisible to its
    # siblings until it lands in a commit -- the isolation the shared-process
    # {Null} baseline does not give.
    #
    # DETACHED HEAD, never a branch. The checkout is `git worktree add --detach`,
    # not a bare add. A bare add auto-creates a branch named after the path
    # basename that `remove --force` never deletes, so N acquire/release cycles
    # leak N orphan branches -- and, worse, re-acquiring a worker_id after a
    # crash would check out that LEAKED branch tip, bleeding a crashed worker's
    # committed state into its successor and defeating isolation on exactly the
    # crash-restart path. Detached HEAD holds no branch: a crashed worker's
    # commits become unreachable when its worktree is reaped, so a re-acquire is
    # always a clean checkout of the base's tip.
    #
    # CUT FROM A BASE, as a SHA. Each acquire reads its {WorkingBranch}'s tip and
    # hands `worktree add` that full SHA, never a name: a name is what git's
    # DWIM turns into a branch checkout. Read per acquire, so a lease taken after
    # a commit lands starts from that commit. A backend built with no base
    # refuses every lease, rather than cutting from whatever HEAD happens to be.
    #
    # UNCOMMITTED WORK IS SCRATCH. Release removes the worktree with `--force`,
    # discarding any uncommitted or untracked files in it. The ONE thing release
    # must never do is leave the checkout on disk, because a leaked worktree
    # silently defeats the next acquire and pollutes `git worktree list` --
    # and refusing to remove a dirty tree would be exactly that leak, since
    # release is how the resource is reclaimed. Durable output leaves a worktree
    # the same way it leaves any checkout: as a commit.
    #
    # A leftover worktree at the target path -- a crash between acquire and
    # release -- is REAPED before add: a best-effort force-remove-then-prune
    # clears a stale registration, while a foreign directory git does not know
    # is left alone so `git worktree add` refuses LOUDLY rather than
    # overwriting it.
    #
    # SERIALIZED per backend. reap-then-add is not atomic: two concurrent
    # acquires of one worker_id would target one path, each reap destroying the
    # other's tree. A {Monitor} serializes reap+add+register, and a path already
    # held by a LIVE lease is a loud {Refused} -- the second concurrent acquire
    # of a worker_id loses cleanly rather than corrupting the first's checkout.
    class Worktree
      # The git-context env vars that redirect where git finds its repository,
      # index, and work tree. A Lain process launched from a git hook --
      # pre-commit exports these -- would otherwise have its shelled `git`
      # resolve the index and dir against the HOOK's repository rather than the
      # leased worktree's, so every git call scrubs them. Mapping each to `nil`
      # deletes it in the child (`Mixlib::ShellOut` and `Process.spawn` agree on
      # that, which is what lets {Shell::Out} and an injected mixlib both run
      # these calls), leaving `-C @repo_root` the sole authority.
      # GIT_CONFIG_PARAMETERS and GIT_CONFIG_COUNT are how a hook's `-c`
      # settings reach its children; without COUNT, the KEY_n/VALUE_n pairs
      # are ignored, so scrubbing it is enough.
      GIT_CONTEXT_SCRUB = {
        "GIT_DIR" => nil, "GIT_INDEX_FILE" => nil, "GIT_WORK_TREE" => nil,
        "GIT_PREFIX" => nil, "GIT_COMMON_DIR" => nil,
        "GIT_CONFIG_PARAMETERS" => nil, "GIT_CONFIG_COUNT" => nil
      }.freeze

      # A refused lease. Surfaced LOUDLY -- the backend never hands back a
      # shared-cwd lease that would silently defeat isolation. Two causes: a git
      # subprocess returned nonzero ({.from_git} -- a dirty parent, an add over
      # a foreign dir, a non-repo root, or a teardown failure), or the path is
      # already held by a live lease.
      class Refused < Error
        # Carries the OPERATION so a teardown-path (`remove`) failure is not
        # mislabeled as an `add`.
        def self.from_git(operation, path, shell)
          new("git worktree #{operation} #{path} failed " \
              "(exit #{shell.exitstatus}): #{shell.stderr.strip}")
        end
      end

      # @param repo_root [String] the repository the worktrees branch from
      # @param root [String] the base directory per-worker worktrees live under
      #   (relocatable, injected -- the {Workspace::Snapshot} root idiom)
      # @param base [#tip, #name] the {WorkingBranch} every lease is cut from;
      #   {WorkingBranch::NONE} refuses every lease
      # @param paths [Paths] supplies the per-worker key via {Paths#project_hash}
      # @param shell_out_factory [#call] builds the subprocess runner, a factory
      #   so a spec substitutes it. {Shell::Out} rather than `Mixlib::ShellOut`
      #   because mixlib FORKS, and a fork copies the parent's page tables:
      #   every `git` here would cost the parent an amount linear in its own
      #   RSS, for a runner whose result is three values. Same argv, same
      #   `environment:` semantics, same timeout, so an injected mixlib works.
      def initialize(root:, repo_root: Dir.pwd, base: WorkingBranch::NONE, paths: Paths.new,
                     shell_out_factory: Shell::Out.public_method(:new))
        @repo_root = File.expand_path(repo_root)
        @root = File.expand_path(root)
        @base = base
        @paths = paths
        @shell_out_factory = shell_out_factory
        @monitor = Monitor.new
        @leased = Set.new
      end

      # @return [#tip, #name] the working branch every lease is cut from, and so
      #   the one a handback of that lease's work targets
      attr_reader :base

      # The reap+add+register is serialized, so a concurrent acquire of the SAME
      # worker_id refuses rather than clobbering.
      # @param worker_id [Object] keyed through {Paths#project_hash} into a
      #   filesystem-safe, collision-resistant per-worker directory name
      # @return [Lease] cwd = the new worktree; release removes it
      # @raise [Refused] if `git worktree add` fails or the path is already leased
      # @raise [WorkingBranch::Refused] if the base names no commit
      def acquire(worker_id)
        path = worktree_path(worker_id)
        base = @monitor.synchronize { check_out(path, worker_id) }
        Lease.new(worker_env: worker_env_for(path, worker_id), on_release: -> { release_path(path) },
                  origin: Lease::Origin.new(path:, base:, branch: @base.name))
      end

      protected

      # The overridable seam a per-service strategy enriches with extra vars
      # (DATABASE_URL, ...) without reshaping this base; `worker_id` rides
      # through so that enrichment can name per-worker vars.
      def worker_env_for(path, _worker_id) = WorkerEnv.new(cwd: path, env: ENV.to_h)

      private

      def worktree_path(worker_id) = File.join(@root, @paths.project_hash(worker_id.to_s))

      # The tip is read before anything touches disk, so a backend with no base
      # refuses leaving nothing behind.
      # @return [String] the SHA the checkout was cut from
      def check_out(path, worker_id)
        raise Refused, "worktree path #{path} is already leased (worker #{worker_id})" if @leased.include?(path)

        base = @base.tip
        FileUtils.mkdir_p(@root)
        reap(path)
        add(path, base)
        @leased << path
        base
      end

      def add(path, commit)
        shell = git("worktree", "add", "--detach", path, commit)
        raise Refused.from_git("add", path, shell) unless shell.exitstatus.zero?
      end

      # Deregister then reclaim, serialized against acquire so a concurrent
      # re-acquire of the path waits for the removal rather than reaping mid-add.
      def release_path(path)
        @monitor.synchronize do
          @leased.delete(path)
          remove(path)
        end
      end

      # `--force` reliably removes a dirty tree; a prune-and-retry clears a stale
      # registration whose directory is already gone. A failure to reclaim is a
      # real leak, so it is raised rather than swallowed.
      def remove(path)
        return if git("worktree", "remove", "--force", path).exitstatus.zero?

        git("worktree", "prune")
        return unless File.exist?(path)

        shell = git("worktree", "remove", "--force", path)
        raise Refused.from_git("remove", path, shell) unless shell.exitstatus.zero?
      end

      # Best-effort. A nonzero exit here means "nothing to reap", or a foreign
      # dir git will refuse to add over, so it is ignored -- the add is what
      # fails loudly.
      def reap(path)
        git("worktree", "remove", "--force", path)
        git("worktree", "prune")
      end

      def git(*)
        shell = @shell_out_factory.call("git", "-C", @repo_root, *, environment: GIT_CONTEXT_SCRUB)
        shell.run_command
        shell
      end
    end
  end
end

# This file is the worktree/ subtree's index. Handback reopens the class above
# and reads its GIT_CONTEXT_SCRUB, so it loads AFTER the class body.
require_relative "worktree/handback"
