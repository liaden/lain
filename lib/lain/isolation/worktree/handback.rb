# frozen_string_literal: true

module Lain
  module Isolation
    class Worktree
      # Give a finished worker's COMMITTED work back to the parent checkout,
      # before its lease is released and the checkout is reclaimed -- and, when
      # that work conflicts, own the way out of the merge it started.
      #
      # AN OPERATION, NOT A LIFECYCLE HOOK. Whoever owns the worker calls this
      # while the lease is still live. Hooking release was the wrong shape twice
      # over: `#release` marks itself released BEFORE running its action, so a
      # raise there strands the path in the backend's leased set, and a chat
      # actor's release only happens deep inside {Supervisor#stop}, next to
      # `@task.stop`. {#continue} and {#abandon} are not that hook either -- they
      # finish the operation {#call} began, on the caller's schedule, and touch
      # no lease at all.
      #
      # REF-FIRST, BECAUSE RECLAIM DESTROYS. A worktree is `--detach`ed and
      # release must never leave a checkout on disk, because a bare `add` leaks
      # a branch a re-acquire would check out, bleeding a crashed worker's state
      # into its successor. So the commits are anchored under
      # `refs/lain/worker/<worker>` and only then merged: reclaim can take the
      # checkout, the ref keeps the work.
      #
      # WHY THAT NAMESPACE, EXACTLY. Not because git cannot check such a ref out
      # -- `git worktree add --detach <path> refs/lain/worker/x` exits 0, and
      # believing otherwise is how the protection gets dropped. The guarantee is
      # narrower and mechanical: {Worktree#add} passes only a full SHA read from
      # its working branch, never a NAME, and the DWIM that invents a checkout
      # from a name consults `refs/heads/` and remote branches alone. Outside
      # `refs/heads/` these refs are unreachable by any add the backend makes
      # and invisible to `git branch`. The corollary is the thing to guard: a
      # NAME reaching {Worktree#add} would reintroduce the bleed -- refuse
      # that, not this namespace.
      #
      # THE REF WITHOUT THE MERGE. {#anchor} is that first half alone, for a
      # caller already unwinding: it writes the ref, merges nothing, and touches
      # no working tree, so an `ensure` racing a cancel can still save the
      # commits the reclaim under it is about to make unreachable. {#call}
      # cannot promise that, since a raise anywhere inside it leaves the ref
      # unwritten.
      #
      # UNCOMMITTED WORK STAYS SCRATCH. This class makes *committed* work
      # survivable and reports what happened. It never spawns, never removes a
      # worktree, and NEVER RAISES -- its caller runs it from a gathered fiber
      # where a raise would take out the worker's own result, so every failure
      # comes back as a `:failed` {Outcome}.
      #
      # "CLEAN PARENT" MEANS NO TRACKED CHANGES. Untracked files are ignored:
      # git itself only refuses a merge that would clobber an untracked file,
      # and a real project checkout nearly always carries scratch files, so
      # counting them as dirty would decline every handback that ever mattered.
      #
      # THE WORKING BRANCH IS THE ONLY TARGET. Given a {WorkingBranch}, a merge
      # declines unless the parent's HEAD is on it: a human who switched away
      # keeps the other branch untouched, and the work waits on its ref.
      #
      # "MERGED" IS MEASURED. After git reports success the parent is asked
      # whether it now contains the worker's commit, so a setting that makes a
      # merge exit 0 without landing anything is `:failed`, never `:merged`.
      class Handback
        # `git status` reports untracked files unless told not to -- see the
        # class doc for why a stray scratch file is not a dirty parent.
        TRACKED_ONLY = "--untracked-files=no"

        # Spelled out on the outcome, because a half-merged parent checkout that
        # nobody was told about is worse than an aborted one.
        IN_PROGRESS = "merge left in progress; resolve the conflicted paths, then #continue or #abandon"
        MID_MERGE = "parent is mid-merge from an earlier handback; #continue or #abandon that one first"
        DIRTY = "parent checkout has uncommitted changes"
        ABANDONED = "merge abandoned; the work is still on the ref"
        ANCHOR_ONLY = "work anchored on the ref; no merge was attempted"

        NO_MERGE = "no merge in progress in the parent checkout"
        RESIDUE = "conflict markers remain in these paths; resolve them and #continue again, or #abandon"

        # Stamped into the ref's reflog, so `git reflog refs/lain/worker/<w>`
        # tells someone holding nothing but the repository that lain wrote this
        # ref, and when.
        #
        # WHO and WHEN, deliberately not WHAT HAPPENED, because the two annotate
        # DIFFERENT OBJECTS: `:merged`, `:declined` and `:nothing_to_do` describe
        # the PARENT CHECKOUT, while a reflog entry describes this ref -- and
        # old->new already encodes the only distinction that is the ref's own,
        # create versus advance.
        ANCHORED = "lain handback: anchored"

        # A caller's `worker_id` as the two names every operation here needs: the
        # KEY the journal joins on, and the REF the work is anchored under.
        #
        # Its own object because none of its rules are about git-the-operation:
        # an arbitrary caller object has to survive `#to_s`, then git's refname
        # alphabet, then an injectivity requirement no other part of this class
        # cares about. Pure -- no shell, no journal, no state.
        class Naming
          # Outside refs/heads/ on purpose -- see {Handback}'s class doc.
          REF_NAMESPACE = "refs/lain/worker"

          # git-check-ref-format rejects spaces, `~^:?*[\`, `@{`, `..`, a leading
          # `.` and a trailing `.` or `.lock`. A worker_id is an arbitrary caller
          # object, so its bytes are slugged into that alphabet rather than
          # trusted -- an id like `arm 1/spawn..x` would otherwise fail the write.
          UNSAFE = /[^A-Za-z0-9._-]+/

          # Long enough to stay readable, short enough that the ref survives a
          # 255-byte filesystem path component once the fingerprint is appended.
          SLUG_LIMIT = 60

          # A blank name would slug to nothing and journal to nothing, and the
          # telemetry guard refuses to record it.
          UNNAMED = "unnamed-worker"

          def initialize(worker_id)
            @name = totally(worker_id)
          end

          def key = @name.strip.empty? ? UNNAMED : @name

          # Fingerprinted on the ORIGINAL name, never on {#key}: `""` and `"   "`
          # are both DISPLAYED as `unnamed-worker`, but they are two workers, and
          # a shared ref would have them overwrite each other.
          def ref = "#{REF_NAMESPACE}/#{slug}-#{fingerprint}"

          private

          # `#to_s` is the caller's own code: it can raise, answer a non-String,
          # or (a BasicObject) not exist at all -- and this is reached from a
          # rescue handler as well as from a method body, where a raise would be
          # a handler re-raising the very thing it was called to contain. Bytes
          # invalid in their own encoding are refused too, since every later
          # `strip`/`gsub` would raise on them.
          def totally(worker_id)
            name = worker_id.to_s
            name.is_a?(String) && name.valid_encoding? ? name : ""
          rescue StandardError
            ""
          end

          # Two workers must never share a ref: `update-ref` overwrites
          # unconditionally, and on a `:declined` or `:conflicted` outcome the
          # ref is the ONLY anchor, so a collision makes one worker's commits
          # unreachable and gc-able. Slugging alone maps `a/b`, `a b` and `a-b`
          # onto one name, so the fingerprint is what makes it injective -- and
          # it also makes the slug a fixpoint, since nothing a caller can spell
          # reconstructs a trailing `.lock` or `.` once hex follows it.
          def slug
            readable = key.gsub(UNSAFE, "-").gsub("..", "-").delete_prefix(".")[0, SLUG_LIMIT]
            readable.empty? ? UNNAMED : readable
          end

          # The hex half only: `Canonical.digest` answers `blake3:<hex>`, and a
          # colon is not legal in a refname.
          #
          # NOT {Paths#project_hash}, which keys the worktree DIRECTORY: it
          # `File.expand_path`es its argument against the process cwd, so `a/b`
          # and `./a/b` collide and one id hashes two ways from two cwds. Fine
          # for a scratch directory keyed once per process, wrong for a durable
          # ref.
          def fingerprint = Canonical.digest(@name).split(":").last[0, 12]
        end

        Outcome = Data.define(:kind, :worker_key, :ref, :paths, :parent_state, :detail, :sha, :fast_forward)

        # What a handback did, and -- the field its caller's next move depends on
        # -- what state that left the parent checkout in.
        #
        # The two {KINDS} a reader cannot infer: `:nothing_to_do` covers commits
        # already in the parent, already on the ref, AND no merge to finish;
        # `:declined` covers a dirty parent, one already mid-merge, an abandoned
        # merge, and an {#anchor} that offered no merge at all. `detail` is what
        # says which.
        #
        # `ref` names where the work is anchored, and is nil ONLY when nothing
        # was written -- `:nothing_to_do` from a {#call}, or a `:failed` that
        # died before the ref write. `paths` is always an Array (empty unless
        # `:conflicted`) and `detail` always a String, so no caller writes a nil
        # guard.
        #
        # `parent_state` is `:untouched`, `:merged`, or `:merging`, and it is
        # MEASURED rather than assumed: after any attempt to unwind a merge the
        # parent is asked whether it is still mid-merge. A `:conflicted` outcome
        # leaves the merge IN PROGRESS on purpose -- the conflicted files carry
        # `<<<<<<<` markers holding both sides, which is the only form in which a
        # resolver that can edit files but cannot run git can see the worker's
        # version at all, and an aborted merge would hand it a clean checkout
        # with nothing to resolve.
        #
        # `sha` is the full SHA that landed in the parent on `:merged` -- the
        # worker's own commit on a fast-forward, the merge commit otherwise --
        # and nil everywhere else. `fast_forward` is MEASURED, the parent's new
        # HEAD against the worker's commit, because a user's `merge.ff = false`
        # turns what looks like a fast-forward into a merge commit.
        #
        # Reopened rather than declared in a `Data.define ... do` block: a
        # constant there is lexically scoped to the enclosing module, not to the
        # Data class.
        class Outcome
          # Every way a handback can end, closed so a caller's branch is total
          # and a kind nobody handles fails at construction, not in a reader.
          KINDS = %i[nothing_to_do merged conflicted declined failed].freeze

          def initialize(kind:, worker_key:, ref: nil, paths: [], parent_state: :untouched, detail: "", sha: nil,
                         fast_forward: false)
            super(kind: known(kind), worker_key: -worker_key.to_s, ref: Freezable::Fields.pinned(ref),
                  paths: Freezable::Fields.pinned_each(paths),
                  parent_state: parent_state.to_sym, detail: -detail.to_s,
                  sha: Freezable::Fields.pinned(sha),
                  fast_forward: Freezable::Fields.boolean!(fast_forward, "fast_forward"))
          end

          # @return [Boolean] whether the parent checkout is sitting mid-merge,
          #   waiting for {Handback#continue} or {Handback#abandon}.
          def merge_in_progress? = parent_state == :merging

          # `:declined` covers two things a caller acts on differently: a parent
          # that REFUSED the merge (worth retrying once it is clean) and an
          # {Handback#anchor} that never offered one (nothing to retry). {KINDS}
          # is closed and widening it would break every exhaustive `case`, so
          # the discrimination is a message rather than a sixth kind.
          #
          # @return [Boolean] whether this outcome came from an anchor-only
          #   write, on which no merge was ever attempted
          def anchor_only? = detail == ANCHOR_ONLY

          # The message shape {Worktree::Refused.from_git} raises with, built as
          # a value instead: nothing propagates to a handback's caller, so the
          # same diagnostic rides back on the Outcome.
          def self.git_failed(key, operation, shell, ref: nil, parent_state: :untouched)
            new(kind: :failed, worker_key: key, ref:, parent_state:,
                detail: "git #{operation} failed (exit #{shell.exitstatus}): #{shell.stderr.strip}")
          end

          private

          def known(kind)
            kind = kind.to_sym
            raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}" unless KINDS.include?(kind)

            kind
          end
        end

        # The merge attempt itself: whether the parent may take one, how it is
        # spelled, and what actually landed. Its own object because refusing,
        # spelling and confirming a merge is a different job from anchoring a
        # ref or concluding a conflict.
        class Merge
          # @param parent [Checkout] the checkout the work comes back to
          # @param strategy [MergeStrategy] how the merge is spelled
          # @param base [WorkingBranch] the only branch the merge may land on
          def initialize(parent:, strategy:, base:)
            @parent = parent
            @strategy = strategy
            @base = base
          end

          # Each check answers the Outcome that stops the merge, or nil to let
          # the next one run.
          # @return [Outcome]
          def call(ref, key) = unplaced(ref, key) || unclean(ref, key) || attempt(ref, key)

          private

          def unplaced(ref, key)
            return declined(ref, key, MID_MERGE) if @parent.merging?

            declined(ref, key, off_branch) unless @base.current_in?(@parent)
          end

          def unclean(ref, key)
            status = @parent.run("status", "--porcelain", TRACKED_ONLY)
            return Outcome.git_failed(key, "status", status, ref:) unless ok?(status)

            declined(ref, key, DIRTY) unless status.stdout.strip.empty?
          end

          def attempt(ref, key)
            shell = @parent.run(*@strategy.merge(ref))
            ok?(shell) ? landed(ref, key) : conflict(ref, key, shell)
          end

          def off_branch
            head = @parent.symbolic_head
            standing = head.empty? ? "a detached HEAD" : head.delete_prefix("refs/heads/")
            "parent checkout is on #{standing}, not the working branch #{@base.name}; the work waits on its ref"
          end

          # git's exit status is not taken as the answer: the parent is asked
          # whether it now holds the worker's commit.
          def landed(ref, key)
            commit = @parent.target(ref)
            return unlanded(ref, key, commit) unless @parent.contains?(commit)

            sha = @parent.head.stdout.strip
            outcome(:merged, key, ref:, parent_state: :merged, sha:, fast_forward: sha == commit)
          end

          def unlanded(ref, key, commit)
            detail = "git merge #{ref} exited 0, but the parent checkout does not contain #{commit}; " \
                     "something outside lain's command line changed what the merge did"
            outcome(:failed, key, ref:, detail:, parent_state: @parent.merging? ? :merging : :untouched)
          end

          # A failed merge WITH unmerged paths is a conflict, and it is left in
          # progress for {Handback#continue} (see {Outcome}). A failed merge with
          # none is something else entirely -- an untracked file the merge would
          # clobber, an unwritable index, a missing committer identity -- so the
          # parent is restored rather than left half-merged with nobody told.
          def conflict(ref, key, shell)
            paths = @parent.unmerged
            return abort_merge(ref, key, shell) if paths.empty?

            outcome(:conflicted, key, ref:, paths:, parent_state: :merging, detail: IN_PROGRESS)
          end

          # The parent is ASKED whether the unwind took, never assumed: `--abort`
          # exits nonzero both when there was no merge to abort (the common case
          # here, where the merge never started) and when the abort itself
          # failed, and only the second leaves a state the caller must hear of.
          def abort_merge(ref, key, shell)
            @parent.run("merge", "--abort")
            Outcome.git_failed(key, "merge #{ref}", shell, ref:, parent_state: @parent.merging? ? :merging : :untouched)
          end

          def declined(ref, key, detail) = outcome(:declined, key, ref:, detail:)

          def outcome(kind, key, **) = Outcome.new(kind:, worker_key: key, **)

          def ok?(shell) = shell.exitstatus.zero?
        end

        # @param repo_root [String] the parent checkout the work comes back to --
        #   the same repository {Worktree} branches its worktrees from
        # @param journal [#<<] where the {Telemetry::Handback} record lands
        # @param strategy [MergeStrategy] how the merge is spelled on git's
        #   command line, so ambient config cannot change the markers
        # @param base [WorkingBranch] the only branch a merge lands on. REQUIRED,
        #   with no default: a caller that forgot it would silently merge into
        #   whatever the parent has checked out. {WorkingBranch::NONE} is the
        #   opt-out, and it is spelled at the call site that takes it.
        # @param shell_out_factory [#call] builds the subprocess runner, a
        #   factory exactly as {Worktree} takes one, defaulting to {Shell::Out}
        #   for the reason {Worktree#initialize} gives: mixlib forks, and this
        #   object spawns git a dozen times per handback
        def initialize(base:, repo_root: Dir.pwd, journal: Channel::Null.instance, strategy: MergeStrategy::DEFAULT,
                       shell_out_factory: Shell::Out.public_method(:new))
          @parent = Checkout.new(File.expand_path(repo_root), shell_out_factory:)
          @journal = journal
          @strategy = strategy
          @merge = Merge.new(parent: @parent, strategy:, base:)
          @shell_out_factory = shell_out_factory
        end

        # Call this while the lease is STILL LIVE: release reclaims the
        # checkout, and there is nothing to read from a worktree that is no
        # longer on disk.
        #
        # @param lease [#worker_env] the live lease whose `worker_env.cwd` is the
        #   worktree to hand back from
        # @param worker_id [Object] names the ref the work is anchored under
        # @return [Outcome] always -- nothing raises past here
        def call(lease, worker_id:)
          named = Naming.new(worker_id)
          journaled(preserve(checkout(lease), named.key, named.ref))
        rescue StandardError => e
          journaled(broke(Naming.new(worker_id).key, nil, e))
        end

        # Anchor `lease`'s committed work under {Naming::REF_NAMESPACE} and stop
        # there: no merge, no staging, no working-tree state anywhere. Call it
        # while the lease is STILL LIVE, for the reason {#call} gives.
        #
        # THIS IS THE OPERATION AN `ensure` CAN AFFORD. {#call} writes the ref
        # and then merges, so an exception raised anywhere in it reclaims a
        # worktree whose commits no ref reaches. This is the ref half alone, and
        # it is idempotent because it reads the ref before writing one -- a
        # second call over the same lease costs two `rev-parse`s and writes
        # nothing. Anchoring is not handing back, so a later {#call} over the
        # same lease still owes the parent its merge.
        #
        # NOTHING GOES UNRECORDED, which is why the rescue here is `Exception`
        # rather than the `StandardError` every other operation in this class
        # keeps. This runs while a worker is being torn down and the worktree is
        # force-removed moments later, so an anchor that failed ENTIRELY is the
        # single event the record must not lose -- a silent Journal makes it
        # indistinguishable from a worker that committed nothing. `Async::Cancel`
        # and `Interrupt` are `< Exception` and are exactly the classes that
        # arrive on this path. The cost is accepted: a cancel that lands inside
        # this method is reported instead of propagated.
        #
        # @param lease [#worker_env] the live lease whose `worker_env.cwd` holds
        #   the commits to anchor. Liveness is NOT checked -- this takes a
        #   one-message duck and only the lifecycle owner can act on a released
        #   lease -- so a released one is a `:failed` outcome and a journal line,
        #   not a refusal.
        # @param worker_id [Object] names the ref, exactly as {#call} names it
        # @return [Outcome] `:declined` once the work is on the ref and the
        #   parent has not taken it (none was offered -- `detail` says so, and
        #   {Outcome#anchor_only?} answers it), `:nothing_to_do` when the parent
        #   already has the commits or the ref already holds them, `:failed`
        #   when git refused or raised -- never a raise
        def anchor(lease, worker_id:)
          named = Naming.new(worker_id)
          journaled(pin(checkout(lease), named.key, named.ref))
        rescue Exception => e # rubocop:disable Lint/RescueException
          journaled(broke(Naming.new(worker_id).key, nil, e))
        end

        # Conclude a merge a `:conflicted` outcome left in progress, once its
        # paths have been resolved. Stages exactly the paths git still reports
        # as unmerged -- never `add -A`, which would sweep a checkout's
        # unrelated scratch into the merge commit. It exists because the
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
          journaled(conclude(ref, Naming.new(worker_id).key))
        rescue StandardError => e
          journaled(broke(Naming.new(worker_id).key, ref, e))
        end

        # Give up on a merge left in progress: the parent goes back to how it
        # was, and the work stays on its ref for a human, or a later handback,
        # to take. The counterpart to {#continue}, and the reason leaving a
        # merge in progress is a decision rather than a trap.
        #
        # @return [Outcome] `:declined` once the parent is clean again,
        #   `:nothing_to_do` if no merge is in progress, `:failed` if the parent
        #   is STILL mid-merge afterwards -- never a raise
        def abandon(ref, worker_id: ref)
          journaled(discard(ref, Naming.new(worker_id).key))
        rescue StandardError => e
          journaled(broke(Naming.new(worker_id).key, ref, e))
        end

        private

        # Built per operation rather than held, because a stale one would name a
        # directory that has been reclaimed.
        def checkout(lease) = Checkout.new(lease.worker_env.cwd, shell_out_factory: @shell_out_factory)

        # "Already has it" is asked as reachability rather than remembered from
        # the add, so a parent that moved on under a worker that committed
        # nothing reads as nothing-to-do too. A ref ALREADY on that commit is
        # left alone rather than rewritten: {#anchor} is retried from an
        # `ensure`, and this is where its idempotence lives.
        def pin(worktree, key, ref)
          head = worktree.head
          return failed(key, "rev-parse HEAD", head) unless ok?(head)

          commit = head.stdout.strip
          return outcome(:nothing_to_do, key) if @parent.contains?(commit)

          held = @parent.target(ref)
          return outcome(:nothing_to_do, key, ref:, detail: ANCHOR_ONLY) if held == commit

          write = @parent.update_ref(ref, commit, held, reason: ANCHORED)
          ok?(write) ? outcome(:declined, key, ref:, detail: ANCHOR_ONLY) : failed(key, "update-ref #{ref}", write)
        end

        # Ref first, then the merge -- and the merge only if there is an anchor
        # to merge FROM. A pin that answered with no ref (nothing to hand back,
        # or git refusing to write) IS the outcome; a pin that found the ref
        # already written by an earlier {#anchor} still owes the parent a merge.
        #
        # THE RESCUE IS WHERE THE REF SURVIVES A RAISE. {#call}'s own
        # method-level rescue cannot name a ref -- it runs where nothing knows
        # whether the write happened -- so a raise from the merge reported the
        # work as lost while it sat safely on disk. This level watched the
        # write, so this is the level that can say where the work is.
        def preserve(worktree, key, ref)
          pinned = pin(worktree, key, ref)
          pinned.ref.nil? ? pinned : @merge.call(ref, key)
        rescue StandardError => e
          broke(key, pinned&.ref, e)
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

          outcome(:merged, key, ref:, parent_state: :merged, sha: @parent.head.stdout.strip)
        end

        def discard(ref, key)
          return outcome(:nothing_to_do, key, ref:, detail: NO_MERGE) unless @parent.merging?

          shell = @parent.run("merge", "--abort")
          return outcome(:declined, key, ref:, detail: ABANDONED) unless @parent.merging?

          failed(key, "merge --abort", shell, ref:, parent_state: :merging)
        end

        def outcome(kind, key, **) = Outcome.new(kind:, worker_key: key, **)

        def failed(key, operation, shell, ref: nil, parent_state: :untouched)
          Outcome.git_failed(key, operation, shell, ref:, parent_state:)
        end

        def broke(key, ref, error) = outcome(:failed, key, ref:, detail: "#{error.class}: #{error.message}")

        # A journal is a report ABOUT a decision and must never overturn one, so
        # a sink that raises -- a closed IO, a real Channel mid-teardown -- or a
        # record the telemetry guard refuses costs the LINE, not the outcome,
        # and not the worker's own result, which a raise from here would take
        # with it, since this runs inside a gathered fiber.
        def journaled(outcome)
          @journal << Telemetry::Handback.new(worker_key: outcome.worker_key, outcome: outcome.kind, ref: outcome.ref,
                                              strategy: @strategy.to_s, fast_forward: outcome.fast_forward,
                                              sha: outcome.sha)
          outcome
        rescue StandardError
          outcome
        end

        def ok?(shell) = shell.exitstatus.zero?
      end
    end
  end
end
