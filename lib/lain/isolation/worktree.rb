# frozen_string_literal: true

require "monitor"
require "fileutils"
require "mixlib/shellout"

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
    # always a clean checkout of the repo's current commit.
    #
    # UNCOMMITTED WORK IS SCRATCH. Release removes the worktree with `--force`,
    # discarding any uncommitted or untracked files in it. A worktree lease is
    # ephemeral scratch, not a place to author durable work: the ONE thing
    # release must never do is leave the checkout on disk, because a leaked
    # worktree silently defeats the next acquire and pollutes the repo's
    # `git worktree list`. Refusing to remove a dirty tree would be exactly that
    # silent leak (release is how the resource is reclaimed), so `--force` is the
    # only choice that keeps the invariant "release always reclaims". Durable
    # output leaves a worktree the same way it leaves any checkout: as a commit.
    #
    # A leftover worktree at the target path (a crash between acquire and
    # release) is REAPED before add, not silently leaked or clobbered: a
    # best-effort force-remove-then-prune clears a stale registration, while a
    # foreign directory that git does not know is left alone so `git worktree
    # add` refuses LOUDLY rather than overwriting it.
    #
    # SERIALIZED per backend. reap-then-add is not atomic: two concurrent
    # acquires of one worker_id would target one path, each reap destroying the
    # other's tree. A {Monitor} serializes reap+add+register, and a path already
    # held by a LIVE lease is a loud {Refused} -- the second concurrent acquire
    # of a worker_id loses cleanly rather than corrupting the first's checkout.
    class Worktree
      # The git-context env vars that redirect where git finds its repository,
      # index, and work tree. A Lain process launched from a git hook (pre-commit
      # exports these) or any GIT_*-polluted env would otherwise have its shelled
      # `git` resolve the index/dir against the WRONG repository -- the hook's,
      # not the leased worktree's -- so every git call scrubs them. Mapping each
      # to `nil` deletes it in the forked child (the {WorkerEnv} scrub semantics
      # B1 pinned: mixlib passes a nil value through as `ENV[k] = nil`), leaving
      # `-C @repo_root` the sole authority on which repo git operates in.
      GIT_CONTEXT_SCRUB = {
        "GIT_DIR" => nil, "GIT_INDEX_FILE" => nil, "GIT_WORK_TREE" => nil,
        "GIT_PREFIX" => nil, "GIT_COMMON_DIR" => nil
      }.freeze

      # A refused lease. Surfaced LOUDLY -- the backend never hands back a
      # shared-cwd lease that would silently defeat isolation. Two causes: a git
      # subprocess returned nonzero ({.from_git} -- a dirty parent, an add over a
      # foreign dir, a non-repo root, or a teardown failure), or the path is
      # already held by a live lease (the concurrency guard). Named per the
      # error-taxonomy convention: a refusal subclasses {Lain::Error} next to the
      # owner that raises it.
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
      # @param paths [Paths] supplies the per-worker key via {Paths#project_hash}
      # @param shell_out_factory [#call] builds the subprocess runner, injected
      #   as a factory exactly as {Tools::Bash} does, so a spec substitutes it
      def initialize(root:, repo_root: Dir.pwd, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @repo_root = File.expand_path(repo_root)
        @root = File.expand_path(root)
        @paths = paths
        @shell_out_factory = shell_out_factory
        @monitor = Monitor.new
        @leased = Set.new
      end

      # Provision an isolated checkout for `worker_id` and hand back the lease
      # whose cwd is that checkout. The reap+add+register is serialized, so a
      # concurrent acquire of the SAME worker_id refuses rather than clobbering.
      # @param worker_id [Object] keyed through {Paths#project_hash} into a
      #   filesystem-safe, collision-resistant per-worker directory name
      # @return [Lease] cwd = the new worktree; release removes it
      # @raise [Refused] if `git worktree add` fails or the path is already leased
      def acquire(worker_id)
        path = worktree_path(worker_id)
        @monitor.synchronize do
          raise Refused, "worktree path #{path} is already leased (worker #{worker_id})" if @leased.include?(path)

          FileUtils.mkdir_p(@root)
          reap(path)
          add(path)
          @leased << path
        end
        Lease.new(worker_env: worker_env_for(path, worker_id), on_release: -> { release_path(path) })
      end

      protected

      # The WorkerEnv a lease hands the worker: the worktree as cwd, the process
      # env otherwise. The overridable seam a per-service strategy (B3/B4)
      # enriches with extra vars (DATABASE_URL, ...) without reshaping this base;
      # `worker_id` rides through so that enrichment can name per-worker vars.
      def worker_env_for(path, _worker_id) = WorkerEnv.new(cwd: path, env: ENV.to_h)

      private

      def worktree_path(worker_id) = File.join(@root, @paths.project_hash(worker_id.to_s))

      def add(path)
        shell = git("worktree", "add", "--detach", path)
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

      # Reclaim the worktree, discarding uncommitted work (see the class doc).
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

      # Best-effort: clear a leftover worktree registration at `path` before the
      # add. A nonzero exit here means "nothing to reap" (or a foreign dir git
      # will refuse to add over), so it is intentionally ignored -- the add is
      # what fails loudly.
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
