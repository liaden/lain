# frozen_string_literal: true

module Lain
  module Isolation
    class Worktree
      # Give a finished worker's COMMITTED work back to the parent checkout,
      # before its lease is released and the checkout is reclaimed -- and, when
      # that work conflicts, own the way out of the merge it started.
      #
      # AN OPERATION, NOT A LIFECYCLE HOOK. Whoever owns the worker calls this
      # while the lease is still live; {Lease#release} keeps exactly the
      # semantics it has today. Hooking release was the wrong shape twice over:
      # `#release` marks itself released BEFORE running its action, so a raise
      # there strands the path in the backend's leased set, and a chat actor's
      # release only happens deep inside {Supervisor#stop}, next to `@task.stop`
      # -- neither is a place to be doing merges. Owning `#continue`/`#abandon`
      # is not that hook: they finish the operation `#call` began, on the
      # caller's schedule, and touch no lease at all.
      #
      # REF-FIRST, BECAUSE RECLAIM DESTROYS. {Worktree}'s class doc explains why
      # a worktree is `--detach`ed and why release must never leave a checkout on
      # disk: a bare `add` leaks a branch a re-acquire would check out, bleeding a
      # crashed worker's state into its successor. So the commits are anchored
      # under `refs/lain/worker/<worker>` and only then merged. Reclaim can take
      # the checkout; the ref keeps the work.
      #
      # WHY THAT NAMESPACE, EXACTLY. Not because git cannot check such a ref out
      # -- `git worktree add --detach <path> refs/lain/worker/x` exits 0, and
      # believing otherwise is how the protection gets dropped. The guarantee is
      # narrower and mechanical: {Worktree#add} passes NO commit-ish, and an add
      # without one checks out HEAD, while the DWIM that invents a checkout from
      # a NAME consults `refs/heads/` (and remote branches) alone. Outside
      # `refs/heads/` these refs are therefore unreachable by any add the backend
      # makes and invisible to `git branch`, so the leaked-branch bleed cannot
      # recur. The corollary is the thing to guard: a future commit-ish argument
      # to {Worktree#add} would reintroduce it -- refuse that, not this namespace.
      #
      # UNCOMMITTED WORK STAYS SCRATCH, exactly as {Worktree} says. This class
      # makes *committed* work survivable and reports what happened. It never
      # spawns, never removes a worktree, and NEVER RAISES -- not from git, not
      # from a caller's nonsense, and not from its own journalling: its caller
      # runs it from a gathered fiber where a raise would take out the worker's
      # own result, so every failure comes back as a `:failed` {Outcome}.
      #
      # "CLEAN PARENT" MEANS NO TRACKED CHANGES. Untracked files are ignored
      # (`--untracked-files=no`): git itself only refuses a merge that would
      # clobber an untracked file, and a real project checkout nearly always
      # carries scratch files, so counting them as dirty would decline every
      # handback that ever mattered. A merge that fails anyway is reported, not
      # forced.
      class Handback
        # Outside refs/heads/ on purpose -- see the class doc.
        REF_NAMESPACE = "refs/lain/worker"

        # git-check-ref-format rejects spaces, `~^:?*[\`, `@{`, `..`, a leading
        # `.` and a trailing `.` or `.lock`. A worker_id is an arbitrary caller
        # object, so its bytes are slugged into that alphabet rather than
        # trusted -- an id like `arm 1/spawn..x` would otherwise fail the write.
        UNSAFE = /[^A-Za-z0-9._-]+/

        # Long enough to stay readable, short enough that the ref survives a
        # 255-byte filesystem path component once the fingerprint is appended.
        SLUG_LIMIT = 60

        # A worker with no name is still a worker: it gets a name here rather
        # than a blank one, which would slug to nothing and journal to nothing.
        UNNAMED = "unnamed-worker"

        # `git status` reports untracked files unless told not to -- see the
        # class doc for why a stray scratch file is not a dirty parent.
        TRACKED_ONLY = "--untracked-files=no"

        # Spelled out on the outcome, because a half-merged parent checkout that
        # nobody was told about is worse than an aborted one.
        IN_PROGRESS = "merge left in progress; resolve the conflicted paths, then #continue or #abandon"
        MID_MERGE = "parent is mid-merge from an earlier handback; #continue or #abandon that one first"
        DIRTY = "parent checkout has uncommitted changes"
        ABANDONED = "merge abandoned; the work is still on the ref"
        NO_MERGE = "no merge in progress in the parent checkout"
        RESIDUE = "conflict markers remain in these paths; resolve them and #continue again, or #abandon"

        # What a handback did, and -- the field its caller's next move depends on
        # -- what state that left the parent checkout in.
        #
        # `kind` is one of {KINDS}: `:nothing_to_do` (the worker's commits are
        # already in the parent, or there was no merge to finish), `:merged`,
        # `:conflicted`, `:declined` (the work is on the ref and the parent did
        # not take it -- a dirty parent, a parent already mid-merge, or an
        # abandoned merge; `detail` says which), `:failed` (a git call failed;
        # the message is in `detail`).
        #
        # `ref` names where the work is anchored, and is nil ONLY when nothing
        # was written -- `:nothing_to_do` from a `#call`, or a `:failed` that
        # died before the ref write. Absence is the signal there, the same
        # nil-is-a-value idiom {Telemetry::MemoryRoot}'s `root` uses. `paths` is
        # always an Array (empty unless `:conflicted`) and `detail` always a
        # String (empty when there is nothing to say), so no caller writes a nil
        # guard.
        #
        # `parent_state` is `:untouched`, `:merged`, or `:merging`, and it is
        # MEASURED rather than assumed: after any attempt to unwind a merge the
        # parent is asked whether it is still mid-merge. A `:conflicted` outcome
        # leaves the merge IN PROGRESS on purpose -- the conflicted files carry
        # `<<<<<<<` markers holding both sides, which is the only form in which a
        # resolver that can edit files but cannot run git can see the worker's
        # version at all, and an aborted merge would hand it a clean checkout
        # with nothing to resolve. {Handback#continue} and {Handback#abandon} are
        # how it ends; `#merge_in_progress?` is how a caller asks.
        Outcome = Data.define(:kind, :worker_key, :ref, :paths, :parent_state, :detail)

        # Reopened rather than declared in a `Data.define ... do` block: a
        # constant there is lexically scoped to the enclosing module, not to the
        # Data class (the pinned Ruby trap {Request::SYSTEM_PREFIX} records).
        class Outcome
          KINDS = %i[nothing_to_do merged conflicted declined failed].freeze

          def initialize(kind:, worker_key:, ref: nil, paths: [], parent_state: :untouched, detail: "")
            kind = kind.to_sym
            raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}" unless KINDS.include?(kind)

            super(kind:, worker_key: -worker_key.to_s, ref: ref&.dup&.freeze,
                  paths: paths.map { |path| -path.to_s }.freeze,
                  parent_state: parent_state.to_sym, detail: -detail.to_s)
          end

          # @return [Boolean] whether the parent checkout is sitting mid-merge,
          #   waiting for {Handback#continue} or {Handback#abandon}.
          def merge_in_progress? = parent_state == :merging
        end

        # One git working tree, questioned. The parent and the leased worktree
        # are the same kind of thing here, so they are one object: a single
        # invocation shape, scrubbed exactly as {Worktree#git} scrubs it, always
        # answering with the shell instead of raising -- this whole operation
        # lives inside a promise that nothing escapes it.
        class Checkout
          # Git's own three marker shapes, in order. Requiring all three, in
          # this order, is what tells a real unresolved hunk from a line of
          # prose (or a diff fixture) that merely starts like one. A false
          # positive costs one round trip and {Handback#abandon} is always
          # available; a false negative commits `<<<<<<<` into the parent's
          # history under a `:merged` outcome, which is the one thing an LLM
          # resolver cannot check for itself.
          CONFLICTED = /^<<<<<<< .*^=======$.*^>>>>>>> /m

          # Paths come off a subprocess's stdout as bytes; the filesystem's own
          # encoding is what they have to be tagged with to compare equal to the
          # same path read any other way.
          FILESYSTEM = Encoding.find("filesystem")

          def initialize(dir, shell_out_factory:)
            @dir = dir
            @shell_out_factory = shell_out_factory
          end

          def run(*)
            shell = @shell_out_factory.call("git", "-C", @dir, *, environment: GIT_CONTEXT_SCRUB)
            shell.run_command
            shell
          end

          def head = run("rev-parse", "HEAD")

          # MERGE_HEAD is git's own record that a merge is under way. Asked of
          # git rather than stat'ed on disk, because a LINKED worktree keeps it
          # somewhere `.git/MERGE_HEAD` is not.
          def merging? = ok?(run("rev-parse", "--verify", "--quiet", "MERGE_HEAD"))

          def contains?(commit) = ok?(run("merge-base", "--is-ancestor", commit, "HEAD"))

          # `-z`, because the default output runs every path through
          # `core.quotePath`: a conflict on `föö.txt` would be reported as
          # `"f\303\266\303\266.txt"`, which no resolver can open and no
          # `git add --` pathspec matches. NUL termination fixes the other half
          # of the same bug for free -- a filename containing a newline, which
          # splitting on "\n" shatters into two paths that do not exist.
          #
          # The bytes then need re-TAGGING, not converting: a binary
          # "f\xC3\xB6\xC3\xB6.txt" is not `==` to the UTF-8 "föö.txt" the same
          # path reads as anywhere else, so an untagged path fails every
          # comparison a caller makes.
          def unmerged
            paths = run("diff", "--name-only", "--diff-filter=U", "-z").stdout.split("\0")
            paths.map { |path| path.force_encoding(FILESYSTEM) }
          end

          # Which of `paths` are still not actually resolved. Only the paths it
          # is asked about are scanned: a marker-shaped line anywhere else in
          # the checkout is none of this operation's business.
          def unresolved(paths) = paths.select { |path| read(path).match?(CONFLICTED) }

          private

          # Binary, because a conflicted file may hold anything and a regex
          # against invalid bytes raises. "" when there is nothing readable
          # there (a delete/modify conflict leaves no file to scan).
          def read(path)
            File.binread(File.join(@dir, path))
          rescue SystemCallError
            ""
          end

          def ok?(shell) = shell.exitstatus.zero?
        end

        # @param repo_root [String] the parent checkout the work comes back to --
        #   the same repository {Worktree} branches its worktrees from
        # @param journal [#<<] where the {Telemetry::Handback} record lands
        # @param shell_out_factory [#call] builds the subprocess runner, injected
        #   as a factory exactly as {Worktree} does, so a spec substitutes it
        def initialize(repo_root: Dir.pwd, journal: Channel::Null.instance,
                       shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @parent = Checkout.new(File.expand_path(repo_root), shell_out_factory:)
          @journal = journal
          @shell_out_factory = shell_out_factory
        end

        # Hand `lease`'s committed work back. Call this while the lease is STILL
        # LIVE: release reclaims the checkout, and there is nothing to read from
        # a worktree that is no longer on disk.
        #
        # @param lease [#worker_env] the live lease whose `worker_env.cwd` is the
        #   worktree to hand back from
        # @param worker_id [Object] names the ref the work is anchored under
        # @return [Outcome] always -- nothing raises past here
        def call(lease, worker_id:)
          name = name_of(worker_id)
          worktree = Checkout.new(lease.worker_env.cwd, shell_out_factory: @shell_out_factory)
          journaled(preserve(worktree, key_for(name), ref_for(name)))
        rescue StandardError => e
          journaled(broke(key_for(name_of(worker_id)), nil, e))
        end

        # Conclude a merge a `:conflicted` outcome left in progress, once its
        # paths have been resolved. Stages exactly the paths git still reports as
        # unmerged -- never `add -A`, which would sweep a checkout's unrelated
        # scratch into the merge commit -- and commits. This exists because the
        # resolver that fixes the files has no way to run git: without it a
        # `:conflicted` handback is terminal, and every later handback into that
        # parent declines forever.
        #
        # @param ref [String] the ref the conflicted outcome named
        # @param worker_id [Object] the journal's join key; defaults to the ref,
        #   which is what a caller holding only the outcome can name
        # @return [Outcome] `:merged`; `:conflicted` again if any staged path
        #   still carries conflict markers (retry after resolving them);
        #   `:nothing_to_do` if no merge is in progress; or `:failed` -- never a
        #   raise
        def continue(ref, worker_id: ref)
          journaled(conclude(ref, key_for(name_of(worker_id))))
        rescue StandardError => e
          journaled(broke(key_for(name_of(worker_id)), ref, e))
        end

        # Give up on a merge left in progress: the parent goes back to how it
        # was, and the work stays on its ref for a human (or a later handback) to
        # take. The counterpart to {#continue}, and the reason leaving a merge in
        # progress is a decision rather than a trap.
        #
        # @return [Outcome] `:declined` once the parent is clean again,
        #   `:nothing_to_do` if no merge is in progress, `:failed` if the parent
        #   is STILL mid-merge afterwards -- never a raise
        def abandon(ref, worker_id: ref)
          journaled(discard(ref, key_for(name_of(worker_id))))
        rescue StandardError => e
          journaled(broke(key_for(name_of(worker_id)), ref, e))
        end

        private

        # Ref first: capture the worktree's HEAD, skip if the parent already has
        # it, anchor it outside refs/heads, and only then try the merge.
        # "Already has it" is asked as reachability rather than remembered from
        # the add, so a parent that moved on under a worker that committed
        # nothing reads as nothing-to-do too.
        def preserve(worktree, key, ref)
          head = worktree.head
          return failed(key, "rev-parse HEAD", head) unless ok?(head)

          commit = head.stdout.strip
          return outcome(:nothing_to_do, key) if @parent.contains?(commit)

          write = @parent.run("update-ref", ref, commit)
          ok?(write) ? merge(ref, key) : failed(key, "update-ref #{ref}", write)
        end

        def merge(ref, key)
          return outcome(:declined, key, ref:, detail: MID_MERGE) if @parent.merging?

          status = @parent.run("status", "--porcelain", TRACKED_ONLY)
          return failed(key, "status", status, ref:) unless ok?(status)
          return outcome(:declined, key, ref:, detail: DIRTY) unless status.stdout.strip.empty?

          shell = @parent.run("merge", "--no-edit", ref)
          ok?(shell) ? outcome(:merged, key, ref:, parent_state: :merged) : conflict(ref, key, shell)
        end

        # A failed merge WITH unmerged paths is a conflict, and it is left in
        # progress for {#continue} (see {Outcome}). A failed merge with none is
        # something else entirely -- an untracked file the merge would clobber,
        # an unwritable index, a missing committer identity -- so the parent is
        # restored rather than left in a half-merged state nobody was told about.
        def conflict(ref, key, shell)
          paths = @parent.unmerged
          return abort_merge(ref, key, shell) if paths.empty?

          outcome(:conflicted, key, ref:, paths:, parent_state: :merging, detail: IN_PROGRESS)
        end

        # The parent is ASKED whether the unwind took, never assumed: `--abort`
        # exits nonzero both when there was no merge to abort (the common case
        # here, where the merge never started) and when the abort itself failed,
        # and only the second leaves a state the caller has to hear about.
        def abort_merge(ref, key, shell)
          @parent.run("merge", "--abort")
          failed(key, "merge #{ref}", shell, ref:, parent_state: @parent.merging? ? :merging : :untouched)
        end

        def conclude(ref, key)
          return outcome(:nothing_to_do, key, ref:, detail: NO_MERGE) unless @parent.merging?

          paths = @parent.unmerged
          residue = @parent.unresolved(paths)
          return finish(ref, key, paths) if residue.empty?

          outcome(:conflicted, key, ref:, paths: residue, parent_state: :merging, detail: RESIDUE)
        end

        def finish(ref, key, paths)
          staged = @parent.run("add", "--", *paths)
          return failed(key, "add", staged, ref:, parent_state: :merging) unless ok?(staged)

          # `commit --no-edit` rather than `merge --continue`: it concludes the
          # same merge with the same MERGE_MSG and never opens an editor.
          committed = @parent.run("commit", "--no-edit")
          return failed(key, "commit", committed, ref:, parent_state: :merging) unless ok?(committed)

          outcome(:merged, key, ref:, parent_state: :merged)
        end

        def discard(ref, key)
          return outcome(:nothing_to_do, key, ref:, detail: NO_MERGE) unless @parent.merging?

          shell = @parent.run("merge", "--abort")
          return outcome(:declined, key, ref:, detail: ABANDONED) unless @parent.merging?

          failed(key, "merge --abort", shell, ref:, parent_state: :merging)
        end

        def outcome(kind, key, **) = Outcome.new(kind:, worker_key: key, **)

        # The message shape {Worktree::Refused.from_git} raises with, built as a
        # value instead: the contract here is that nothing propagates to the
        # caller, so the same diagnostic rides back on the Outcome.
        def failed(key, operation, shell, ref: nil, parent_state: :untouched)
          detail = "git #{operation} failed (exit #{shell.exitstatus}): #{shell.stderr.strip}"
          outcome(:failed, key, ref:, detail:, parent_state:)
        end

        def broke(key, ref, error) = outcome(:failed, key, ref:, detail: "#{error.class}: #{error.message}")

        # A journal is a report ABOUT a decision and must never overturn one, so
        # a sink that raises (a closed IO, a real Channel mid-teardown) or a
        # record the telemetry guard refuses costs the LINE, not the outcome --
        # and not the worker's own result, which a raise from here would take
        # with it (this runs inside a gathered fiber).
        def journaled(outcome)
          @journal << Telemetry::Handback.new(worker_key: outcome.worker_key, outcome: outcome.kind, ref: outcome.ref)
          outcome
        rescue StandardError
          outcome
        end

        def ok?(shell) = shell.exitstatus.zero?

        # The caller's worker_id as a String, TOTALLY. `#to_s` is the caller's
        # own code: it can raise, answer a non-String, or (a BasicObject) not
        # exist at all -- and this runs in the rescue handler as well as in the
        # body, where a raise would be a handler re-raising the very thing it
        # was called to contain. An id whose bytes are not valid in their own
        # encoding is refused here too, since every later `strip`/`gsub` would
        # raise on it.
        def name_of(worker_id)
          name = worker_id.to_s
          name.is_a?(String) && name.valid_encoding? ? name : ""
        rescue StandardError
          ""
        end

        # A worker with no usable name is still a worker: naming it beats a
        # blank the telemetry guard refuses to record.
        def key_for(name) = name.strip.empty? ? UNNAMED : name

        # Fingerprinted on the ORIGINAL name, never on {#key_for}'s: `""` and
        # `"   "` are both DISPLAYED as `unnamed-worker`, but they are two
        # workers, and a shared ref would have them overwrite each other.
        def ref_for(name) = "#{REF_NAMESPACE}/#{slug(key_for(name))}-#{fingerprint(name)}"

        # Two workers must never share a ref: `update-ref` overwrites
        # unconditionally, and on a `:declined` or `:conflicted` outcome the ref
        # is the ONLY anchor, so a collision makes one worker's commits
        # unreachable and gc-able. The readable half is what a human greps for;
        # the fingerprint is what makes the mapping injective, since slugging
        # alone maps `a/b`, `a b` and `a-b` onto one name. It also makes the
        # slug a fixpoint: nothing a caller can spell reconstructs a trailing
        # `.lock` or `.` once hex follows it.
        #
        # NOT {Paths#project_hash}, which keys the worktree DIRECTORY: it
        # `File.expand_path`es its argument against the process cwd, so `a/b`
        # and `./a/b` collide and one id hashes two ways from two cwds. Fine for
        # a scratch directory keyed once per process; wrong for a durable ref.
        def slug(key)
          readable = key.gsub(UNSAFE, "-").gsub("..", "-").delete_prefix(".")[0, SLUG_LIMIT]
          readable.empty? ? UNNAMED : readable
        end

        # The hex half of the content address: `Canonical.digest` answers
        # `blake3:<hex>`, and a colon is not legal in a refname.
        def fingerprint(name) = Canonical.digest(name).split(":").last[0, 12]
      end
    end
  end
end
