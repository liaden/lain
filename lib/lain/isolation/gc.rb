# frozen_string_literal: true

require "tmpdir"

module Lain
  module Isolation
    # Reaps what lain's workers leave behind once their work is safe
    # elsewhere: checkouts under lain's own worktree root, anchors under
    # `refs/lain/worker/`, and working branches lain created and marked under
    # {WorkingBranch::OWNED}. Nothing else is ever enumerated, and {Repo}
    # refuses to delete any other ref, so the scope is a refusal rather than a
    # convention. Nothing is ever pushed.
    #
    # SAFE ELSEWHERE MEANS A LOCAL BRANCH REACHES IT. Reached from the trunk,
    # the work landed; reached from any other branch, it folded into that
    # branch. A checkout or anchor nothing reaches is the only place its work
    # lives, so it is kept.
    #
    # A LIVE LEASE IS NEVER TOUCHED. Liveness is read off the checkout's own
    # {LeaseLock}, never off a journal, which a run may not have kept. A lock
    # lain cannot parse, or one taken on another host, is kept too.
    #
    # EXPIRY NEVER LOSES WORK. A checkout past `retain_days` goes only after its
    # committed HEAD and, when the tree is dirty, a snapshot of its whole
    # working state are both on anchors; the record says `kept` and names them.
    # A young dirty tree is always kept.
    #
    # IGNORED FILES ARE NOT KEPT, by design: a snapshot takes what `git add
    # --all` takes, and ignored files are the ones a project declared
    # regenerable. The keep report says so wherever a snapshot was taken. A
    # tree holding a NESTED REPOSITORY cannot be snapshotted at all, since
    # that repository's objects live in its own `.git`: it is kept on disk and
    # reported, never removed.
    #
    # NOTHING IS UNLOCKED BLINDLY. Between the look and the act another
    # process may have taken the path, so every removal first CLAIMS the lock
    # it judged ({Worktree::Registry#claim}); a lock that changed is left as
    # it now is, and the checkout kept.
    #
    # AN ANCHOR NO BRANCH REACHES IS KEPT INDEFINITELY, the reaper's own expiry
    # anchors and snapshots included. A deliberate limit rather than an
    # oversight: an anchor costs one ref, a lost worker commit cannot be got
    # back, so nothing here ages an anchor out.
    #
    # IDEMPOTENT: every verdict is recomputed from git and the filesystem, and
    # every ref write is a compare-and-swap, so a second run over the same
    # state reaps nothing.
    class Gc
      DAY = 86_400

      # An expired checkout's work could not be put on an anchor, so the
      # checkout stays.
      class Unanchored < Error; end

      # @param repo_root [String] any checkout of the repository
      # @param root [String] lain's worktree root for that repository; nothing
      #   outside it is touched
      # @param retain_days [Integer] how long an unmerged or dirty checkout is kept
      # @param journal [#<<] where each {Telemetry::WorktreeReap} lands
      # @param process_table [LeaseLock::ProcessTable] judges lease locks
      # @param clock [#call] answers now
      # @param trunk [String] the branch whose reach means landed
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(repo_root:, root:, retain_days:, journal: Channel::Null.instance,
                     process_table: LeaseLock::ProcessTable.new, clock: -> { Time.now },
                     trunk: WorkingBranch::TRUNK, shell_out_factory: Shell::Out.public_method(:new))
        repo_root = File.expand_path(repo_root)
        registry = Worktree::Registry.new(repo_root:, shell_out_factory:)
        repo = Repo.new(Checkout.new(repo_root, shell_out_factory:), trunk:)
        # In this order: expiring a checkout writes anchors, which the anchor
        # pass then reports on in the same run.
        @passes = [Checkouts.new(registry:, repo:, root:, table: process_table, clock:, retain_days:,
                                 shell_out_factory:),
                   Anchors.new(repo:), Branches.new(repo:, registry:)]
        @journal = journal
      end

      # @return [Array<Telemetry::WorktreeReap>] every reap and keep, in the
      #   order they were decided, each also journaled
      def call = @passes.flat_map(&:call).each { |record| @journal << record }.freeze

      # The two records the reaper writes.
      module Records
        def self.kept(subject, name, reason, anchors = [])
          Telemetry::WorktreeReap.new(action: :kept, subject:, name:, reason:, anchors:)
        end

        def self.reaped(subject, name, reason)
          Telemetry::WorktreeReap.new(action: :reaped, subject:, name:, reason:)
        end

        # git's stderr on one line: a reason is one line of a report.
        def self.flat(text) = text.to_s.lines.map(&:strip).reject(&:empty?).join("; ")
      end

      # The repository, questioned and changed only within the reaper's scope.
      class Repo
        WORKER = Worktree::Handback::Naming::REF_NAMESPACE

        def initialize(git, trunk:)
          @git = git
          @trunk = trunk
        end

        attr_reader :trunk

        # @return [Array<Array(String, String)>] each ref under `prefix` and its commit
        def refs(prefix)
          @git.run("for-each-ref", "--format=%(refname) %(objectname)", "#{prefix}/").stdout.split("\n").map(&:split)
        end

        # @return [String] the commit `ref` names, or "" for none
        def tip(ref) = @git.target(ref)

        # Against the branch by its full name: a tag of the trunk's name would
        # otherwise win git's disambiguation.
        def merged?(commit) = @git.ancestor?(commit, "refs/heads/#{trunk}")

        # @return [String] "landed on <trunk>", "folded into <branches>", or ""
        #   when no local branch reaches `commit`
        def landing(commit)
          names = @git.run("for-each-ref", "--format=%(refname)", "--contains", commit, "refs/heads/")
                      .stdout.split("\n").map { |ref| ref.delete_prefix("refs/heads/") }
          return "landed on #{trunk}" if names.include?(trunk)

          names.empty? ? "" : "folded into #{names.join(", ")}"
        end

        # Compare-and-swapped against `held`, so a ref that moved while the
        # reaper looked is left where it now is.
        # A command, not a query: the boolean is only so a caller can tell a
        # lost swap from a delete, which PredicateMethod misreads as a name.
        # @return [Boolean] whether the ref was deleted
        def delete(ref, held) # rubocop:disable Naming/PredicateMethod
          scoped!(ref)
          @git.run("update-ref", "-d", ref, held).exitstatus.zero?
        end

        # Created against "must not exist"; a ref already on `commit` is the
        # same anchor written by an earlier run.
        # @raise [Unanchored] when `ref` does not end up holding `commit`
        def anchor(ref, commit, reason:)
          scoped!(ref)
          return if @git.update_ref(ref, commit, "", reason:).exitstatus.zero? || @git.target(ref) == commit

          raise Unanchored, "#{ref} could not be written"
        end

        private

        def scoped!(ref)
          return if ref.start_with?("refs/lain/") || owned?(ref)

          # A delete aimed at a ref outside what lain created. Raised, never
          # rescued: reaching it is a defect in the reaper, not a state to report.
          raise Error, "lain's reaper deletes only refs under refs/lain/ and branches lain marked, not #{ref}"
        end

        def owned?(ref)
          name = ref.delete_prefix("refs/heads/")
          ref.start_with?("refs/heads/") && name != trunk && !tip("#{WorkingBranch::OWNED}/#{name}").empty?
        end
      end

      # A commit of a checkout's whole working state, tracked and untracked,
      # built through a temporary index: neither the checkout's own index nor
      # the repository's shared stash stack is touched.
      class Snapshot
        # lain made the commit, so lain is its author; a user's identity may
        # also simply be unset where the reaper runs.
        IDENTITY = { "GIT_AUTHOR_NAME" => "lain", "GIT_AUTHOR_EMAIL" => "lain@localhost",
                     "GIT_COMMITTER_NAME" => "lain", "GIT_COMMITTER_EMAIL" => "lain@localhost" }.freeze

        MESSAGE = "lain gc: the uncommitted state of an expired worker checkout"

        STAGED = "lain gc: the staged state of an expired worker checkout"

        # A gitlink entry in `ls-files --stage`, capturing its path.
        GITLINK = /\A160000 \h+ \d+\t(.+)\z/

        def initialize(dir, shell_out_factory:)
          @dir = dir
          @shell_out_factory = shell_out_factory
        end

        # The working state's first parent is HEAD and its second is the
        # checkout's own index, committed as it stands, so content staged and
        # then changed again in the working copy survives too.
        # @return [String] the snapshot commit
        # @raise [Unanchored] when any step fails, or the tree holds a nested repository
        def commit
          staged = staged_commit
          Dir.mktmpdir("lain-gc-index") do |tmp|
            env = Worktree::GIT_CONTEXT_SCRUB.merge(IDENTITY, "GIT_INDEX_FILE" => File.join(tmp, "index"))
            step(env, "read-tree", "HEAD")
            step(env, "add", "--all")
            refuse_nested(env)
            step(env, "commit-tree", step(env, "write-tree"), "-p", "HEAD", "-p", staged, "-m", MESSAGE)
          end
        end

        private

        def staged_commit
          own = Worktree::GIT_CONTEXT_SCRUB.merge(IDENTITY)
          step(own, "commit-tree", step(own, "write-tree"), "-p", "HEAD", "-m", STAGED)
        end

        # A gitlink whose repository keeps a `.git` DIRECTORY of its own: its
        # objects are nowhere this repository can reach. A registered
        # submodule's `.git` is a file pointing into this repository, so it is
        # not one.
        def refuse_nested(env)
          gitlinks = step(env, "ls-files", "--stage").split("\n").filter_map { |line| line[GITLINK, 1] }
          nested = gitlinks.select { |path| File.directory?(File.join(@dir, path, ".git")) }
          return if nested.empty?

          raise Unanchored, "it holds a nested repository at #{nested.join(", ")}, whose work lives in its own " \
                            ".git and cannot be snapshotted"
        end

        def step(env, *args)
          shell = @shell_out_factory.call("git", "-C", @dir, *args, environment: env)
          shell.run_command
          unless shell.exitstatus.zero?
            raise Unanchored, "git #{args.first} failed in #{@dir}: #{Records.flat(shell.stderr)}"
          end

          shell.stdout.strip
        end
      end

      # One checkout's clock: when it stops being young.
      Age = Data.define(:deadline, :now) do
        def expired? = now > deadline

        def to_s = deadline.utc.iso8601
      end

      # Every registered checkout under the root, judged and, where its work is
      # safe or anchored, removed.
      class Checkouts
        ANCHORED = "lain gc: anchored an expired checkout's work"

        CHANGED = "its lock changed while gc ran"

        GONE = "its checkout is gone, so its registration was dropped"

        IGNORED = "; ignored files are not kept"

        def initialize(registry:, repo:, root:, table:, clock:, retain_days:, shell_out_factory:)
          @registry = registry
          @repo = repo
          @roots = Project::Resolver.spellings(File.expand_path(root), File)
          @table = table
          @clock = clock
          @retain_days = retain_days
          @shell_out_factory = shell_out_factory
        end

        def call = @registry.entries.select { |entry| inside?(entry.path) }.map { |entry| judge(entry) }

        private

        def inside?(path)
          Project::Resolver.spellings(path, File).any? do |spelling|
            @roots.any? { |root| spelling.start_with?("#{root}/") }
          end
        end

        def judge(entry)
          reason = holding(entry)
          return Records.kept(:worktree, entry.path, reason) unless reason.empty?
          return vanished(entry) unless File.directory?(entry.path)

          settle(entry, age(entry))
        end

        # An interrupted claim first: it leaves a tree reading as unlocked
        # whatever held it before.
        # @return [String] why something else holds the checkout, or "" when nothing does
        def holding(entry)
          interrupted = @registry.interrupted(entry.path)
          return interrupted unless interrupted.empty?

          entry.lock.held?(@table) ? entry.lock.why(@table) : ""
        end

        def age(entry)
          Age.new(deadline: entry.lock.aged_from(created(entry.path)) + (@retain_days * DAY), now: @clock.call)
        end

        def settle(entry, age)
          dirty = @registry.uncommitted?(entry.path)
          landing = @repo.landing(entry.head)
          return expire(entry, dirty:, landing:) if age.expired? && (dirty || landing.empty?)
          return Records.kept(:worktree, entry.path, "uncommitted changes; retained until #{age}") if dirty
          return reap(entry, landing) unless landing.empty?

          Records.kept(:worktree, entry.path, "unmerged commits; retained until #{age}")
        end

        def expire(entry, dirty:, landing:)
          anchors = unreached(entry, dirty:, landing:).map { |kind, commit| anchor(entry.path, kind, commit) }
          refusal = remove(entry)
          Records.kept(:worktree, entry.path, refusal.empty? ? expired(anchors, dirty) : refusal, anchors)
        rescue Unanchored => e
          Records.kept(:worktree, entry.path, "expired, but left on disk: #{e.message}")
        end

        # @return [Hash{String=>String}] each kind of work only this checkout
        #   holds, and the commit that holds it
        def unreached(entry, dirty:, landing:)
          { "head" => (entry.head if landing.empty?), "snapshot" => (snapshot(entry.path) if dirty) }.compact
        end

        def snapshot(path) = Snapshot.new(path, shell_out_factory: @shell_out_factory).commit

        # Named for the checkout, the kind of work and the commit, so a rerun
        # over the same checkout names the same ref rather than a second one.
        def anchor(path, kind, commit)
          Worktree::Handback::Naming.new("gc #{File.basename(path)} #{kind} #{commit}").ref
                                    .tap { |ref| @repo.anchor(ref, commit, reason: ANCHORED) }
        end

        def expired(anchors, dirty)
          "expired after #{@retain_days} days; its work is kept on #{anchors.join(", ")}#{IGNORED if dirty}"
        end

        def reap(entry, reason)
          refusal = remove(entry)
          refusal.empty? ? Records.reaped(:worktree, entry.path, reason) : Records.kept(:worktree, entry.path, refusal)
        end

        # Only ever reached for a checkout {#call} found under the root; the
        # guard makes a regression there a refusal rather than a deletion. The
        # lock is claimed against what was judged, never simply unlocked.
        # @return [String] "" once the checkout is gone, or why it was kept
        def remove(entry)
          path = entry.path
          raise Error, "lain's reaper removes only checkouts under its own root, not #{path}" unless inside?(path)
          return CHANGED unless @registry.claim(entry)

          shell = @registry.remove(path)
          shell.exitstatus.zero? ? "" : "git would not remove it: #{Records.flat(shell.stderr)}"
        end

        # git still records the HEAD of a checkout whose directory is gone, and
        # that record may be all that holds a crashed worker's commit: it is
        # anchored before the registration goes.
        def vanished(entry)
          anchors = @repo.landing(entry.head).empty? ? [anchor(entry.path, "head", entry.head)] : []
          refusal = remove(entry)
          refusal.empty? ? gone(entry.path, anchors) : Records.kept(:worktree, entry.path, refusal, anchors)
        rescue Unanchored => e
          Records.kept(:worktree, entry.path, "its checkout is gone, but its commit is not anchored: #{e.message}")
        end

        def gone(path, anchors)
          return Records.reaped(:worktree, path, GONE) if anchors.empty?

          Records.kept(:worktree, path, "#{GONE}; its commit is kept on #{anchors.join(", ")}", anchors)
        end

        # `worktree add` writes the checkout's `.git` file and nothing rewrites
        # it, so its mtime is when the checkout was cut. One that cannot be
        # read counts as cut now, which errs towards keeping.
        def created(path)
          File.mtime(File.join(path, ".git"))
        rescue SystemCallError
          @clock.call
        end
      end

      # Every worker anchor, deleted once a branch reaches its commit.
      class Anchors
        def initialize(repo:)
          @repo = repo
        end

        def call = @repo.refs(Repo::WORKER).map { |ref, commit| judge(ref, commit) }

        private

        def judge(ref, commit)
          landing = @repo.landing(commit)
          return Records.kept(:anchor, ref, "no branch reaches #{commit[0, 12]}") if landing.empty?
          return Records.reaped(:anchor, ref, landing) if @repo.delete(ref, commit)

          Records.kept(:anchor, ref, "it moved while gc ran")
        end
      end

      # Every branch lain marked as its own, deleted with its marker once
      # something landed on it and it merged into the trunk.
      class Branches
        def initialize(repo:, registry:)
          @repo = repo
          @registry = registry
        end

        def call = @repo.refs(WorkingBranch::OWNED).map { |marker, marked| judge(marker, marked) }

        private

        def judge(marker, marked)
          branch = "refs/heads/#{marker.delete_prefix("#{WorkingBranch::OWNED}/")}"
          tip = @repo.tip(branch)
          return orphaned(marker, marked) if tip.empty?

          reason = hold(branch, tip, marked)
          reason.empty? ? reap(branch, tip, marker, marked) : Records.kept(:branch, branch, reason)
        end

        # The marker holds the SHA the branch was created at, which is the
        # trunk's tip at that moment: a branch still there has had nothing land
        # on it, and "merged" would be true of it trivially.
        # @return [String] why the branch stays, or "" when it may go
        def hold(branch, tip, marked)
          return "it is #{@repo.trunk}, which is never reaped" if branch == "refs/heads/#{@repo.trunk}"
          return "nothing has landed on it since lain created it" if tip == marked
          return "not merged into #{@repo.trunk}" unless @repo.merged?(tip)

          in_use(branch)
        end

        # A rebase in progress detaches its checkout, so the porcelain names no
        # branch for it, yet finishing the rebase rewrites the branch by name.
        def in_use(branch)
          entries = @registry.entries
          holders = entries.select { |entry| entry.branch == branch }.map(&:path)
          return "checked out at #{holders.join(", ")}" unless holders.empty?

          rebasers = entries.select { |entry| @registry.rebasing(entry.path) == branch }.map(&:path)
          rebasers.empty? ? "" : "being rebased at #{rebasers.join(", ")}"
        end

        # The branch first, while its marker still licenses the delete.
        def reap(branch, tip, marker, marked)
          return Records.kept(:branch, branch, "it moved while gc ran") unless @repo.delete(branch, tip)

          @repo.delete(marker, marked)
          Records.reaped(:branch, branch, "merged into #{@repo.trunk}")
        end

        def orphaned(marker, marked)
          return Records.reaped(:branch, marker, "its branch no longer exists") if @repo.delete(marker, marked)

          Records.kept(:branch, marker, "it moved while gc ran")
        end
      end
    end
  end
end
