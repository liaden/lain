# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/undo`: put back the files the most recent file-changing turn wrote,
      # and nothing else. The conversation is `/rewind`'s, so the Timeline never
      # moves here; typed again, it walks one turn further back.
      #
      # What to put back is {Workspace::SnapshotLog#undo}'s question, and the
      # move is {Workspace::Revert}'s. Every refusal lands before anything
      # moves, as `/rewind`'s do:
      #
      # * while a turn is in flight or a supervised worker is live, since
      #   either may still write after the files are put back;
      # * when the root the snapshot recorded is gone or unreadable -- a
      #   plan-scope spike a later `/mode` flip tore down -- since that root is
      #   both where the turn's files go back and where planning the undo reads
      #   its trees;
      # * when any path blocks the undo. The refusal names each one and why,
      #   and says what to do: put it back by hand, or `/undo skip`, which drops
      #   that turn without restoring anything so the next undo reaches the one
      #   before. A refusal with no way past it would wedge every later undo.
      #
      # A turn is named by its place among the file-changing turns, never by a
      # digest nobody can act on.
      #
      # The record is journaled AFTER the revert, where `/rewind` journals
      # first. Its pointer move cannot fail, but a file write can, and the
      # record then names exactly what landed.
      class Undo
        class Refusal < Error; end

        SKIP = "skip"

        NOTHING = "nothing to undo: no turn has changed a file this session recorded"

        WRITE_SET_ONLY = "Only files lain's own tools wrote were restored: that turn ran under the write-set " \
                         "scope, which records nothing a shell did."

        IN_FLIGHT = "cannot undo while a turn is in flight: a tool call may still be parked, and it could " \
                    "write after the files are put back"

        # Both refusals over the root a snapshot recorded. It is a path the
        # human likely never typed, so each names the likeliest reason it is
        # unreachable -- a plan-scope spike -- as a guess, since all the code
        # knows is that a directory is missing or shut. And each offers the
        # repair before the skip, as a blocked path's refusal does: skipping
        # discards the turn, so it is the fallback, never the only way out.
        GONE_ROOT = "cannot undo %<place>s: it wrote under %<root>s, which no longer exists -- perhaps a " \
                    "plan-scope spike a later /mode flip tore down, or a directory removed since. Put it " \
                    "back and /undo again, or /undo skip to drop that turn without restoring anything. " \
                    "Nothing was changed."

        UNREADABLE_ROOT = "cannot undo %<place>s: its files were recorded under %<root>s, which lain can no " \
                          "longer read -- perhaps a plan-scope spike a later /mode flip tore down, taking " \
                          "its shadow store with it. Make that root readable and /undo again, or /undo skip " \
                          "to drop that turn without restoring anything. Nothing was changed. git said: %<why>s"

        # Why a path blocks an undo, in the words the refusal uses.
        REASONS = {
          dirty: "was changed since that turn",
          symlink: "is a symlink, which undo neither follows nor restores",
          directory: "has a file or directory in the way that the turn did not make",
          outside_root: "is outside the project root",
          ignored: "is .gitignore'd, so nothing recorded what it held before",
          unrecorded: "was written by that turn, but nothing recorded what it held before lain first wrote it",
          nested_repository: "is inside a nested repository, which undo cannot put back"
        }.freeze

        # The journal's record of one undo: the turn reverted, its snapshot, and
        # the paths written back and deleted.
        WorkspaceUndone = Data.define(:turn, :snapshot, :written, :deleted) do
          include ::Lain::Telemetry::Journalable
        end

        # The journal's record of a turn dropped without restoring anything:
        # its changes stayed on disk.
        WorkspaceUndoSkipped = Data.define(:turn, :snapshot) do
          include ::Lain::Telemetry::Journalable
        end

        def initialize = freeze

        def name = "undo"

        def usage
          "/undo [skip] -- restore the files the last file-changing turn wrote (again to go further back), " \
            "or skip that turn without restoring anything; the conversation stays -- /rewind moves that"
        end

        def call(args, env)
          skipping = skipping?(args)
          quiet!(env)
          return NOTHING if env.snapshots.log.none?

          skipping ? skipped(env) : reverted(env, standing!(env))
        end

        private

        def skipping?(args)
          argument = args.to_s.strip
          return argument == SKIP if ["", SKIP].include?(argument)

          raise Refusal, "unknown /undo argument #{argument.inspect}: type /undo, or /undo skip"
        end

        # Addressed under the root the snapshot recorded, never the one the
        # slot holds now: a `/mode` flip rebinds the slot, while a snapshot's
        # file map stays keyed relative to the root that recorded it. Undoing a
        # plan-scope turn from the checkout would resolve those keys against the
        # checkout -- other files entirely, and a path absent there blocks
        # nothing, so it wrote to the wrong file without refusing.
        #
        # The obstruction scan is handed to {Workspace::Revert#apply} rather
        # than left for it to repeat: it reads the content of every path the
        # turn changed, so scanning twice read the whole change set twice.
        def reverted(env, root)
          undo = planned(env, root)
          revert = ::Lain::Workspace::Revert.new(root:)
          found = revert.blockers(undo.moves)
          blocked!(undo, undo.blocked + found)
          landed(env, undo, revert.apply(undo.moves, found))
        end

        # A shadow turn's moves are read from its trees under the recorded
        # root, so every way `git -C <root>` can fail is a way the PLAN fails,
        # and no predicate in front of it can enumerate them -- a root that
        # exists but cannot be entered is one. So the plan's own failure is
        # what becomes the refusal, and git's words ride along: "Permission
        # denied" and a reaped shadow store want different answers.
        def planned(env, root)
          env.snapshots.log.undo(store: env.timeline.store)
        rescue ::Lain::Workspace::Snapshot::Scope::ShadowGit::Failed => e
          raise Refusal, format(UNREADABLE_ROOT, place: place(env.snapshots.log.count), root:, why: e.message)
        end

        # The write-set arm plans without asking git anything, and a restore
        # under it would MAKE the missing directories it writes into -- putting
        # a torn-down spike's files back into a resurrected tree. So a gone root
        # is still answered before the plan, and answered in its own words.
        def standing!(env)
          root = recorded_root(env)
          return root if Dir.exist?(root)

          raise Refusal, format(GONE_ROOT, place: place(env.snapshots.log.count), root:)
        end

        # Every snapshot payload names the root it was taken under, so the
        # record being undone carries its own answer.
        def recorded_root(env) = env.timeline.store.fetch(latest(env).snapshot).body.fetch("root")

        # The log records in order, so its last entry is the one an undo takes:
        # the entry {Workspace::SnapshotLog#undo} plans from and {#skip} drops.
        def latest(env) = env.snapshots.log.to_a.last

        # Disk moved: the slot learns it first, so its next write is measured
        # from here, then the journal, then the human.
        def landed(env, undo, result)
          env.snapshots.undone(undo)
          journal(env, WorkspaceUndone.new(turn: undo.turn, snapshot: undo.snapshot, **result.to_h))
          rendered(undo, result)
        end

        def skipped(env)
          skip = env.snapshots.skip
          journal(env, WorkspaceUndoSkipped.new(turn: skip.turn, snapshot: skip.snapshot))
          "skipped #{place(skip.remaining)} without restoring anything: its changes stay on disk#{next_undo(skip)}"
        end

        # `remaining` counts the skipped turn itself, so ONE means it was the
        # last undoable turn there was -- claiming "/undo now reaches the turn
        # before it" over that is a promise with nothing behind it, since there
        # is no earlier undoable turn to reach.
        def next_undo(skip)
          return "; no earlier undoable turn remains" if skip.remaining == 1

          ", and /undo now reaches the turn before it"
        end

        def journal(env, record) = env.chronicle.record_journal << record

        def quiet!(env)
          raise Refusal, IN_FLIGHT if InFlight.dispatching?(env)

          live = env.supervisor.each.select { |worker| worker.state == :running }
          return if live.empty?

          names = live.map { |worker| "#{worker.role} (#{worker.worker_id})" }.join(", ")
          raise Refusal, "cannot undo while #{names} is still running and may be writing; " \
                         "let it settle or stop it first"
        end

        def blocked!(undo, blockers)
          return if blockers.empty?

          named = blockers.map { |blocker| "#{blocker.key} #{REASONS.fetch(blocker.reason)}" }.join("; ")
          raise Refusal, "cannot undo #{place(undo.remaining)}: #{named}. Put those back by hand and /undo again, " \
                         "or /undo skip to drop that turn without restoring anything. Nothing was changed."
        end

        def rendered(undo, result)
          text = "undid #{place(undo.remaining)}: #{moves(result)}"
          undo.write_set? ? "#{text}. #{WRITE_SET_ONLY}" : text
        end

        def moves(result)
          said = { "restored" => result.written, "deleted" => result.deleted }
                 .reject { |_, keys| keys.empty? }.map { |verb, keys| "#{verb} #{keys.join(", ")}" }
          said.empty? ? "no file needed putting back" : said.join("; ")
        end

        # Counted among the turns still undoable: a count that took in turns
        # already undone read as "2 of 3" with two left. Takes the count rather
        # than a planned undo because the refusals over a recorded root land
        # BEFORE the plan, where the log's own size is that number -- every
        # entry it still holds is still undoable.
        def place(remaining)
          return "the only undoable file-changing turn" if remaining == 1

          "the latest of #{remaining} undoable file-changing turns"
        end
      end
    end
  end
end
