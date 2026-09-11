# frozen_string_literal: true

require "pathname"

module Lain
  class Workspace
    # Puts a recorded snapshot's file state back on disk -- the write side of
    # {Event::Projection#workspace_at}. Restoring is STATE, not overlay: the
    # write-set becomes exactly the target map, so files the target does not hold
    # are deleted (an empty map -- a total-deletion snapshot -- restores to
    # nothing).
    #
    # The conversation axis is untouched by construction: Restore never sees a
    # Timeline, so "restore files, keep conversation" is not a behavior to get
    # right but a dependency that does not exist. Rewinding both axes is this
    # plus {Timeline#rewind}; they compose because they share only the turn
    # number.
    #
    # A bare class, not an Effect behind {Effect::Handler::Gate}: the Gate tiers
    # MODEL-initiated tool calls (the danger axis is "does the model control the
    # string"), and Restore is operator-initiated bench machinery in the same
    # trust domain as {Timeline#rewind}'s pointer movement.
    #
    # Keys are workspace-root-relative (the recorded format), so the INJECTED
    # root decides where they land; the payload's recorded "root" is provenance,
    # never authority -- that is what lets a relocated checkout restore where it
    # lives now.
    #
    # ONE Restore per session, like one {Snapshot} writer per session: the
    # in-force ledger ("what did lain itself last put on disk") is writer state,
    # not log content. A fresh instance constructed after another one restored
    # backward re-seeds from the log's LAST snapshot, mistakes the prior
    # instance's writes for out-of-band edits, and refuses Dirty -- loud and
    # recoverable with force:, but not the intended usage.
    #
    # Undoing ONE turn's own paths is a different job, and {Revert}'s.
    class Restore
      include OnDisk

      class NoSnapshot < Error; end
      class Dirty < Error; end
      class EscapesRoot < Error; end

      # A mid-apply IO failure: disk holds a state no snapshot recorded, and this
      # names exactly what landed before it (relative keys; the underlying IO
      # error is #cause). The in-force ledger advanced per successful operation,
      # so a retry stays loud-and-safe: spurious {Dirty} at worst, never a silent
      # clobber off a stale ledger.
      class PartialApply < Error
        attr_reader :written, :deleted

        def initialize(error, written:, deleted:)
          @written = written.freeze
          @deleted = deleted.freeze
          super("restore applied only partially (#{error.message}): " \
                "written #{written.inspect}, deleted #{deleted.inspect}")
        end
      end

      # Relative keys, in map order -- what one restore did, for the caller
      # (frontend, journal) to report.
      Result = Data.define(:written, :deleted)

      # The record one #apply keeps as it goes: the in-force map advanced per
      # SUCCESSFUL operation, and which keys have landed. Exists so a mid-apply
      # failure leaves @in_force truthful -- assigning the target map only after
      # a completed loop left a franken-disk behind a ledger still claiming the
      # pre-restore state.
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

      # Refuses BEFORE any IO -- {EscapesRoot} for keys outside the root
      # (always), {Dirty} for on-disk bytes the record does not hold (unless
      # forced) -- so a refused restore leaves disk exactly as it found it.
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

      # The map disk is held accountable to: seeded from the log's last snapshot,
      # then advanced by this writer's own restores -- which keeps a second
      # restore from mistaking the first one's writes for out-of-band edits.
      def in_force
        @in_force ||= latest_files
      end

      def latest_files
        snapshot = @projection.workspace_at(ANY_TURN)
        snapshot.nil? ? {} : snapshot.body.fetch("files")
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
      # blob -- and ABSENT where it says present is clean too, because a missing
      # file has no bytes to clobber and restoring is the recovery.
      def clean?(key)
        actual = read(key)
        expected = in_force[key]
        actual.nil? || (!expected.nil? && actual == @store.fetch(expected).bytes)
      end

      # Each success is recorded in the ledger before the next operation runs;
      # the ensure keeps @in_force truthful whatever interrupts the loops. An IO
      # failure surfaces as {PartialApply} naming what landed, the raw Errno
      # riding along as its #cause.
      def apply(target, doomed)
        ledger = Ledger.new(in_force)
        begin
          doomed.each { |key| take_away(key, ledger) }
          target.each { |key, digest| put_back(key, digest, ledger) }
        rescue SystemCallError => e
          raise PartialApply.new(e, written: ledger.written, deleted: ledger.deleted)
        ensure
          @in_force = ledger.map.freeze
        end
        ledger.result
      end

      def take_away(key, ledger)
        remove(key)
        ledger.deleted!(key)
      end

      def put_back(key, digest, ledger)
        place(key, @store.fetch(digest).bytes)
        ledger.written!(key, digest)
      end
    end
  end
end
