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

        # Why a path blocks an undo, in the words the refusal uses.
        REASONS = {
          dirty: "was changed since that turn",
          symlink: "is a symlink, which undo neither follows nor restores",
          directory: "has a file or directory in the way that the turn did not make",
          outside_root: "is outside the project root",
          ignored: "is .gitignore'd, so nothing recorded what it held before",
          unrecorded: "was first written in that turn, and nothing recorded what it held before",
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

        # The in-flight half of the quiet check, shared with `/rewind`: a run
        # holding the dispatch lock has a tool call that may still settle --
        # onto the files an undo puts back, or onto the Timeline a rewind moves.
        def self.in_flight?(env) = env.agent.dispatching?

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

          skipping ? skipped(env) : reverted(env, env.snapshots.log.undo(store: env.timeline.store))
        end

        private

        def skipping?(args)
          argument = args.to_s.strip
          return argument == SKIP if ["", SKIP].include?(argument)

          raise Refusal, "unknown /undo argument #{argument.inspect}: type /undo, or /undo skip"
        end

        # The obstruction scan is handed to {Workspace::Revert#apply} rather
        # than left for it to repeat: it reads the content of every path the
        # turn changed, so scanning twice read the whole change set twice.
        def reverted(env, undo)
          revert = ::Lain::Workspace::Revert.new(root: env.snapshots.root)
          found = revert.blockers(undo.moves)
          blocked!(undo, undo.blocked + found)
          landed(env, undo, revert.apply(undo.moves, found))
        end

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
          "skipped #{place(skip)} without restoring anything: its changes stay on disk, and /undo now " \
            "reaches the turn before it"
        end

        def journal(env, record) = env.chronicle.record_journal << record

        def quiet!(env)
          raise Refusal, IN_FLIGHT if self.class.in_flight?(env)

          live = env.supervisor.each.select { |worker| worker.state == :running }
          return if live.empty?

          names = live.map { |worker| "#{worker.role} (#{worker.worker_id})" }.join(", ")
          raise Refusal, "cannot undo while #{names} is still running and may be writing; " \
                         "let it settle or stop it first"
        end

        def blocked!(undo, blockers)
          return if blockers.empty?

          named = blockers.map { |blocker| "#{blocker.key} #{REASONS.fetch(blocker.reason)}" }.join("; ")
          raise Refusal, "cannot undo #{place(undo)}: #{named}. Put those back by hand and /undo again, " \
                         "or /undo skip to drop that turn without restoring anything. Nothing was changed."
        end

        def rendered(undo, result)
          text = "undid #{place(undo)}: #{moves(result)}"
          undo.write_set? ? "#{text}. #{WRITE_SET_ONLY}" : text
        end

        def moves(result)
          said = { "restored" => result.written, "deleted" => result.deleted }
                 .reject { |_, keys| keys.empty? }.map { |verb, keys| "#{verb} #{keys.join(", ")}" }
          said.empty? ? "no file needed putting back" : said.join("; ")
        end

        # Counted among the turns still undoable: a count that took in turns
        # already undone read as "2 of 3" with two left.
        def place(turn)
          return "the only undoable file-changing turn" if turn.remaining == 1

          "the latest of #{turn.remaining} undoable file-changing turns"
        end
      end
    end
  end
end
