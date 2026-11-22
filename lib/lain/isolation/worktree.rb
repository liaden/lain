# frozen_string_literal: true

require "monitor"
require "fileutils"

module Lain
  module Isolation
    # Isolation by `git worktree`: each worker leases its own checkout of the
    # repo under a per-worker path, with the lease's cwd pointing there, and the
    # checkout is reclaimed on release. Two workers acquired from the same repo
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
    # crash-restart path. A re-acquire is always a clean checkout of the base's
    # tip.
    #
    # CUT FROM A BASE, as a SHA. Each acquire reads its {WorkingBranch}'s tip and
    # hands `worktree add` that full SHA, never a name: a name is what git's
    # DWIM turns into a branch checkout. Read per acquire, so a lease taken after
    # a commit lands starts from that commit. A backend built with no base
    # refuses every lease, rather than cutting from whatever HEAD happens to be.
    #
    # LOCKED WHILE LEASED. The add takes a `git worktree lock` whose reason names
    # this process ({LeaseLock::Held}), in the same command, so there is no
    # moment a leased checkout is unlocked. That lock is how anything outside
    # this process -- the reaper, or a restarted run -- tells a live checkout
    # from a crash's leftover, with or without a journal.
    #
    # NOTHING A WORKER MADE IS DISCARDED ({Release}). A checkout holding
    # uncommitted or untracked changes, or one git cannot read, is RETAINED:
    # re-locked as {LeaseLock::Retained} and left on disk for {Gc} to age out,
    # anchoring its state before it goes. A clean one has any commit no ref
    # reaches anchored under `refs/lain/worker/`, then is removed. {#retained?}
    # tells the releaser which happened.
    #
    # A leftover checkout at the target path is either a crash's or one retained
    # on release, and neither is destroyed. It is moved aside under
    # `retained/` and the new checkout takes the path. One whose lock names a
    # live process is somebody else's lease, and the acquire refuses LOUDLY. A
    # foreign directory git does not know is left alone, so `git worktree add`
    # refuses rather than overwriting it.
    #
    # EARLIER WORK IS HELD FOR THE LEASE THAT READS IT ({#hold_earlier_work}). A
    # tree moved aside, or a new lane's newest earlier checkout retained in
    # place, is locked as held by this process with its old age, so {Gc}
    # leaves it while the lease can read it, and locked as retained again
    # when the lease ends.
    #
    # SERIALIZED per repository. Adds, removes, moves and prunes of one
    # repository's worktrees run one at a time across threads, fibers and
    # processes ({RepoLock}), because {Spike} builds a backend per call and a
    # second lain process may share the repository; git can otherwise read a
    # worktree entry another command is still writing.
    #
    # SERIALIZED per backend. clear-then-add is not atomic: two concurrent
    # acquires of one worker_id would target one path. A {Monitor} serializes
    # clear+add+register, and a path already held by a lease of this backend is
    # a loud {Refused} -- the second concurrent acquire of a worker_id loses
    # cleanly rather than corrupting the first's checkout.
    class Worktree
      # The git-context env vars that change which repository, objects, index,
      # work tree, namespace or history a git command sees. A Lain process
      # launched from a git hook -- pre-commit exports these -- would otherwise
      # have its shelled `git` resolve them against the HOOK's repository (or
      # replacement refs, grafts and shallow file) rather than the leased
      # worktree's, so every git call scrubs them. Mapping each to `nil`
      # deletes it in the child (`Process.spawn` semantics, which {Shell::Out}
      # follows), leaving `-C <repository>` the sole authority.
      # GIT_CONFIG_PARAMETERS and GIT_CONFIG_COUNT are how a hook's `-c`
      # settings reach its children; without COUNT, the KEY_n/VALUE_n pairs
      # are ignored, so scrubbing it is enough. Never a blanket `GIT_*`:
      # GIT_CONFIG_GLOBAL is set on purpose in specs.
      GIT_CONTEXT_SCRUB = {
        "GIT_DIR" => nil, "GIT_INDEX_FILE" => nil, "GIT_WORK_TREE" => nil,
        "GIT_PREFIX" => nil, "GIT_COMMON_DIR" => nil,
        "GIT_OBJECT_DIRECTORY" => nil, "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil,
        "GIT_NAMESPACE" => nil, "GIT_CEILING_DIRECTORIES" => nil,
        "GIT_DISCOVERY_ACROSS_FILESYSTEM" => nil, "GIT_REPLACE_REF_BASE" => nil,
        "GIT_NO_REPLACE_OBJECTS" => nil, "GIT_GRAFT_FILE" => nil, "GIT_SHALLOW_FILE" => nil,
        "GIT_IMPLICIT_WORK_TREE" => nil,
        "GIT_CONFIG_PARAMETERS" => nil, "GIT_CONFIG_COUNT" => nil
      }.freeze

      # In a partial clone a read that meets a missing object fetches it through
      # the program the repository's own `remote.<name>.uploadpack` names, so a
      # cloned repository could run code through lain's reads; with this set the
      # read fails instead. Only lain's own git gets it: a project's checks and
      # suite run under the bare scrub, and may fetch as their author's do.
      NO_LAZY_FETCH = { "GIT_NO_LAZY_FETCH" => "1" }.freeze

      # The env every git lain spawns runs under, but for 4 sites that merge only {NO_LAZY_FETCH}: an approval
      # asks git what a model's command would see (ComposedTerm::Repository, Judgement, LeaseCommit), and the
      # shadow repository keeps the user's global config, so each scrubs to its own rule rather than this one.
      GIT_SPAWN_ENV = GIT_CONTEXT_SCRUB.merge(NO_LAZY_FETCH).freeze

      # Where leftovers are moved aside, under the worktree root so the reaper
      # finds them with everything else it owns.
      RETAINED = "retained"

      # A refused lease. Surfaced LOUDLY -- the backend never hands back a
      # shared-cwd lease that would silently defeat isolation. Three causes: a
      # git subprocess returned nonzero ({.from_git} -- a dirty parent, an add
      # over a foreign dir, a non-repo root, or a teardown failure), the path
      # is already held by a lease of this backend, or its leftover is locked
      # by a live process or by something lain did not write.
      class Refused < Error
        # Carries the OPERATION so a teardown-path (`remove`) failure is not
        # mislabeled as an `add`, and the registry's label so a clone's is not
        # mislabeled as a worktree's.
        def self.from_git(operation, path, shell, label: Registry::LABEL)
          new("#{label} #{operation} #{path} failed " \
              "(exit #{shell.exitstatus}): #{shell.stderr.strip}")
        end
      end

      # @param repo_root [String] the repository the worktrees branch from
      # @param root [String] the base directory per-worker worktrees live under
      #   (relocatable, injected -- the {Workspace::Snapshot} root idiom)
      # @param base [#tip, #name] the {WorkingBranch} every lease is cut from;
      #   {WorkingBranch::NONE} refuses every lease
      # @param paths [Paths] supplies the per-worker key via {Paths#project_hash}
      # @param process_table [LeaseLock::ProcessTable] names this process in
      #   each lease lock, and judges the lock on a leftover
      # @param clock [#call] answers now, stamped into a retention lock
      # @param shell_out_factory [#call] builds the subprocess runner, a factory
      #   so a spec substitutes it. {Shell::Out} spawns rather than forks, so a
      #   `git` here costs the parent nothing linear in its own RSS.
      # @param registry [Registry, Clone::Registry] how checkouts are cut, listed, locked and reclaimed
      def initialize(root:, repo_root: Dir.pwd, base: WorkingBranch::NONE, paths: Paths.new,
                     process_table: LeaseLock::ProcessTable.new, clock: -> { Time.now },
                     shell_out_factory: Shell::Out.public_method(:new),
                     registry: Registry.new(repo_root: File.expand_path(repo_root), shell_out_factory:))
        @root = File.expand_path(root)
        @base = base
        @paths = paths
        @process_table = process_table
        @registry = registry
        @leftover = Leftover.new(registry: @registry, root: @root, process_table:, clock:)
        @release = Release.new(registry: @registry, clock:)
        @monitor = Monitor.new
        @repo_lock = RepoLock.for(repo_root)
        @leased = Set.new
        @retained = Set.new
        @asides = {}
      end

      # @return [#tip, #name] the working branch every lease is cut from, and so
      #   the one a handback of that lease's work targets
      attr_reader :base

      # {Registry} already holds the expanded path every git call in it runs
      # against, so this reads that rather than keeping a second copy.
      # @return [String] the repository every lease is cut FROM -- the one a
      #   handback merges into, read here rather than re-derived by a caller
      #   that would otherwise shell its own `rev-parse --show-toplevel` and
      #   risk answering a different repository than the one this backend cuts
      #   worktrees from
      def repo_root = @registry.repo_root

      # The clear+add+register is serialized, so a concurrent acquire of the
      # SAME worker_id refuses rather than clobbering.
      # @param worker_id [Object] keyed through {Paths#project_hash} into a
      #   filesystem-safe, collision-resistant per-worker directory name
      # @return [Lease] cwd = the new worktree; release reclaims it
      # @raise [Refused] if `git worktree add` fails, the path is already leased,
      #   or a live process holds the leftover there
      # @raise [WorkingBranch::Refused] if the base names no commit
      def acquire(worker_id)
        path = worktree_path(worker_id)
        base = @monitor.synchronize { check_out(path) }
        on_release = ->(discard: false) { release_path(path, discard:) }
        Lease.new(worker_env: worker_env_for(path, worker_id), on_release:,
                  origin: Lease::Origin.new(path:, base:, branch: @base.name))
      rescue Refused => e
        # The path is a hash of the worker id, so a refusal naming only the
        # path cannot say whose lease it was.
        raise Refused, "worker #{worker_id}: #{e.message}"
      end

      # @param path [String] a lease's checkout, as its origin names it
      # @return [Boolean] whether its release kept it on disk for its
      #   uncommitted work, rather than removing it
      def retained?(path) = @monitor.synchronize { @retained.include?(path) }

      # A lease whose acquire moved nothing aside is a new lane, and takes the
      # newest earlier worker's checkout a release retained in place instead.
      #
      # @param path [String] a lease's checkout, as its origin names it
      # @param earlier [Array<Object>] earlier worker ids, newest first
      # @return [Array<String>] each earlier checkout held for that lease to
      #   read until it is released
      def hold_earlier_work(path, earlier: [])
        @monitor.synchronize do
          if @leased.include?(path) && @asides.fetch(path, []).empty?
            @asides[path] = @repo_lock.synchronize { @leftover.hold(earlier.map { worktree_path(_1) }) }
          end
          @asides.fetch(path, []).map(&:path)
        end
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
      def check_out(path)
        raise Refused, "#{@registry.label} at #{path} is already leased" if @leased.include?(path)

        base = @base.tip
        FileUtils.mkdir_p(@root)
        @repo_lock.synchronize { added(path, base, @leftover.clear(path)) }
        @leased << path
        @retained.delete(path)
        base
      end

      def added(path, commit, asides)
        shell = @registry.add(path, commit, reason: @process_table.current.reason)
        raise Refused.from_git("add", path, shell, label: @registry.label) unless Shell::Out.ok?(shell)

        @asides[path] = asides
      rescue Refused
        asides.each { @leftover.restore(_1) }
        raise
      end

      # Deregister then reclaim, serialized against acquire so a concurrent
      # re-acquire of the path waits for the release rather than clearing
      # mid-add.
      def release_path(path, discard: false)
        @monitor.synchronize do
          @leased.delete(path)
          @retained << path if @release.call(path, discard:) == :retained
        ensure
          @asides.delete(path).to_a.each { @leftover.restore(_1) }
        end
      end
    end
  end
end
