# frozen_string_literal: true

require "fileutils"
require "pathname"

module Lain
  class Workspace
    # Puts a recorded snapshot's file state back on disk -- the write side of
    # {Event::Projection#workspace_at}, as {Snapshot} is the write side of the
    # record itself. Restoring is STATE, not overlay: the write-set becomes
    # exactly the target map, so files the target does not hold are deleted
    # (an empty map -- W1's total-deletion snapshot -- restores to nothing).
    #
    # The conversation axis is untouched by construction: Restore never sees a
    # Timeline, so "restore files, keep conversation" is not a behavior to get
    # right but a dependency that does not exist. Rewinding both axes is this
    # plus {Timeline#rewind}; they compose because they share only the turn
    # number.
    #
    # A bare class, not an Effect behind {Effect::Handler::Gate}: the Gate
    # tiers MODEL-initiated tool calls (the danger axis is "does the model
    # control the string"). Restore is operator-initiated bench machinery in
    # the same trust domain as {Timeline#rewind}'s pointer movement, and
    # follows Snapshot's bare-class precedent on the other side of the record.
    #
    # Keys are workspace-root-relative (W1 froze that format), so the INJECTED
    # root decides where they land; the payload's recorded "root" is
    # provenance, never authority -- that is what lets a relocated checkout
    # restore where it lives now.
    #
    # ONE Restore per session, like one {Snapshot} writer per session, and for
    # the mirrored reason: the in-force ledger ("what did lain itself last put
    # on disk") is writer state, not log content. A fresh instance constructed
    # after another one restored backward re-seeds from the log's LAST
    # snapshot, mistakes the prior instance's writes for out-of-band edits,
    # and refuses Dirty -- loud and recoverable with force:, but not the
    # intended usage.
    class Restore
      class NoSnapshot < Error; end
      class Dirty < Error; end
      class EscapesRoot < Error; end

      # A mid-apply IO failure: disk holds a state no snapshot recorded, and
      # this error names exactly what landed before the failure (relative
      # keys; the underlying IO error is #cause). The in-force ledger has
      # advanced per successful operation, so a retry stays loud-and-safe:
      # spurious {Dirty} at worst, never a silent clobber off a stale ledger.
      class PartialApply < Error
        attr_reader :written, :deleted

        def initialize(error, written:, deleted:)
          @written = written.freeze
          @deleted = deleted.freeze
          super("restore applied only partially (#{error.message}): " \
                "written #{written.inspect}, deleted #{deleted.inspect}")
        end
      end

      # Relative keys, in map order -- the observable record of what one
      # restore did, for the caller (frontend, journal) to report.
      Result = Data.define(:written, :deleted)

      # The record one #apply keeps as it goes: the in-force map advanced per
      # SUCCESSFUL operation, and which keys have landed. Exists so a mid-apply
      # failure leaves @in_force truthful (FIX 2, panel probe 6) -- assigning
      # the target map only after a completed loop left a franken-disk behind
      # a ledger still claiming the pre-restore state.
      class Ledger
        attr_reader :map, :written, :deleted

        def initialize(map)
          @map = map.dup
          @written = []
          @deleted = []
        end

        def deleted!(key)
          @map.delete(key)
          @deleted << key
        end

        def written!(key, digest)
          @map[key] = digest
          @written << key
        end

        def result
          Result.new(written: written.freeze, deleted: deleted.freeze)
        end
      end

      # workspace_at's window test is `count <= turn`, so infinity selects the
      # log's LAST snapshot: the state the record currently asserts is on disk.
      ANY_TURN = Float::INFINITY

      # @param projection [Event::Projection] the read side; a log that has
      #   grown means constructing a new Projection, and so a new Restore
      # @param store [Store] resolves the file map's blob digests to bytes
      # @param root [String] where relative keys land -- defaults to the same
      #   base Snapshot defaults its relativization to
      def initialize(projection:, store:, root: Dir.pwd)
        @projection = projection
        @store = store
        @root = Pathname.new(File.expand_path(root)).freeze
        @in_force = nil
      end

      # Restore the snapshot in force at `turn`. Refuses BEFORE any IO --
      # {EscapesRoot} for keys outside the root (always), {Dirty} for on-disk
      # bytes the record does not hold (unless `force:`) -- so a refused
      # restore leaves disk exactly as it found it.
      #
      # @param turn [Integer] as {Event::Projection#workspace_at} counts turns
      # @param force [Boolean] waive the dirty check; never the confinement
      # @return [Result]
      # @raise [NoSnapshot, EscapesRoot, Dirty]
      def restore(turn:, force: false)
        target = files_at(turn)
        doomed = in_force.keys - target.keys
        # target + doomed IS target ∪ in-force: every path restore may touch.
        managed = target.keys + doomed
        confine!(managed)
        refuse_symlinks!(managed)
        refuse_dirty!(managed) unless force
        apply(target, doomed)
      end

      private

      def files_at(turn)
        snapshot = @projection.workspace_at(turn)
        raise NoSnapshot, "no :snapshot at or before turn #{turn}" if snapshot.nil?

        snapshot.body.fetch("files")
      end

      # The map disk is held accountable to: seeded from the log's last
      # snapshot, then advanced by this writer's own restores -- which is what
      # keeps a second restore (forward or back) from mistaking the first
      # one's writes for out-of-band edits. Stateful like {Snapshot}'s
      # last-files skip, and for the same reason: "what did lain itself last
      # put here" is writer state, not log content.
      def in_force
        @in_force ||= latest_files
      end

      def latest_files
        snapshot = @projection.workspace_at(ANY_TURN)
        snapshot.nil? ? {} : snapshot.body.fetch("files")
      end

      # The panel's condition: "../" keys are refuse-or-confine -- we REFUSE,
      # wholly and before any write, force or not. A partial "confined"
      # restore would leave disk in a state no snapshot ever recorded, which
      # is a quieter lie than a named refusal. Lexical, matching Snapshot's
      # lexical relativization.
      def confine!(keys)
        escaped = keys.reject { |key| within_root?(key) }
        return if escaped.empty?

        raise EscapesRoot,
              "refusing to restore outside #{@root}: #{escaped.join(", ")}"
      end

      def within_root?(key)
        path = File.expand_path(key, @root.to_s)
        path == @root.to_s || path.start_with?("#{@root}#{File::SEPARATOR}")
      end

      # FIX 1 (panel probe 8): the lexical key check cannot see a symlink AT
      # the path, and File.binwrite follows links -- a link planted at a
      # managed path would carry recorded bytes wherever it points, including
      # outside the root. So a symlink refuses exactly like an escaping key
      # does: never followed, never confined-and-written, force notwithstanding.
      # Refused even when it points inside the root, because the snapshot
      # recorded a regular file and writing through a link restores something
      # else. lstat-only (File.symlink?), so nothing is dereferenced to decide.
      def refuse_symlinks!(keys)
        linked = keys.select { |key| File.symlink?(absolute(key)) }
        return if linked.empty?

        raise EscapesRoot,
              "refusing to restore through symlinks (the record holds regular files): #{linked.join(", ")}"
      end

      def refuse_dirty!(keys)
        dirty = keys.reject { |key| clean?(key) }
        return if dirty.empty?

        raise Dirty,
              "refusing to clobber bytes the record does not hold (modified outside lain " \
              "since the last snapshot; pass force: true to overwrite): #{dirty.join(", ")}"
      end

      # Clean means the on-disk bytes deviate in nothing a restore could lose:
      # absent where the in-force map says absent, byte-equal where it names a
      # blob -- and ABSENT where it says present is clean too, because a
      # missing file has no bytes to clobber and restoring is the recovery.
      def clean?(key)
        actual = read(key)
        expected = in_force[key]
        actual.nil? || (!expected.nil? && actual == @store.fetch(expected).bytes)
      end

      # nil for no regular file, including one deleted between check and read
      # -- the same TOCTOU collapse Snapshot makes, because here too the race
      # resolves to the absence it raced.
      def read(key)
        path = absolute(key)
        File.file?(path) ? File.binread(path) : nil
      rescue Errno::ENOENT
        nil
      end

      # Deletes then writes, each success recorded in the ledger before the
      # next operation runs; the ensure keeps @in_force truthful whatever
      # interrupts the loops. An IO failure surfaces as {PartialApply} naming
      # what landed -- the raw Errno rides along as its #cause.
      def apply(target, doomed)
        ledger = Ledger.new(in_force)
        begin
          doomed.each { |key| remove(key, ledger) }
          target.each { |key, digest| place(key, digest, ledger) }
        rescue SystemCallError => e
          raise PartialApply.new(e, written: ledger.written, deleted: ledger.deleted)
        ensure
          @in_force = ledger.map.freeze
        end
        ledger.result
      end

      def remove(key, ledger)
        delete(key)
        ledger.deleted!(key)
      end

      def place(key, digest, ledger)
        write(key, @store.fetch(digest).bytes)
        ledger.written!(key, digest)
      end

      def write(key, bytes)
        path = absolute(key)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
      end

      # Already-absent is the goal, not an error: a file deleted out of band
      # (or by a racing delete) needs nothing from us.
      def delete(key)
        File.delete(absolute(key))
      rescue Errno::ENOENT
        nil
      end

      def absolute(key)
        File.expand_path(key, @root.to_s)
      end
    end
  end
end
