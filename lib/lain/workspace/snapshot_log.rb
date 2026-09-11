# frozen_string_literal: true

module Lain
  class Workspace
    # A chat's in-process record of the snapshots it took, and what `/undo`
    # asks what to put back. {Agent::SnapshotSlot} records each snapshot here
    # as it lands, with the turn's trees when its scope staged them; nothing
    # else could find them again, since a :snapshot event has no render parent
    # and the {Store} has no enumerator.
    #
    # An undo reverts exactly one turn's own change.
    #
    # * A shadow turn's change is the difference between the tree staged just
    #   before its tools ran and the one staged after: deletions and mode
    #   changes included, and nothing the human did between turns. A path a
    #   structured tool wrote that git never stages (a .gitignore'd one, or one
    #   outside the root) is a change those trees cannot put back, so the undo
    #   names it rather than skipping it.
    # * A write-set turn's change is each path its map changed, back to that
    #   path's latest EARLIER record. A path with no earlier record may have
    #   been a human's file before lain first wrote it, so the undo names it as
    #   unrecorded rather than guess it did not exist.
    #
    # An undone record leaves the history, so a later turn's undo never takes
    # its bytes for a pre-image -- disk went back past it. Mutable, one per
    # session, like the writer it records.
    class SnapshotLog
      include Enumerable

      class Moved < Error; end

      # One recorded snapshot, as digests: the turn it names as its cause, its
      # own digest, its file map (path => blob digest) and its scope note.
      Entry = Data.define(:turn, :snapshot, :files, :scope)

      Undo = Data.define(:turn, :snapshot, :scope, :moves, :blocked, :remaining)

      # A turn dropped without restoring anything, counted the same way.
      Skipped = Data.define(:turn, :snapshot, :remaining)

      # @param observer [#call] every recorded snapshot is passed on to it, so a
      #   durable record can hang off the same seam
      def initialize(observer: Event::ChainWriter::Null.new)
        @observer = observer
        @entries = []
        @pairs = {}
      end

      def each(&block)
        return enum_for(:each) unless block_given?

        @entries.each(&block)
        self
      end

      # The observer duck: a snapshot with no trees behind it.
      def call(event) = record(event)

      # @param event [Event] the :snapshot the writer just landed
      # @param pair [#staged?, #moved?, #moves, #keys, #ignored?] the turn's trees
      # @return [self]
      def record(event, pair: Snapshot::Scope::NoTrees)
        keep(Entry.new(turn: event.causal_parents.first, snapshot: event.digest,
                       files: event.body.fetch("files"), scope: event.body.fetch("snapshot_scope")), pair)
        @observer.call(event)
        self
      end

      # @param store [Store] resolves a write-set record's blob digests to bytes
      # @return [Undo] {Undo::NOTHING} when no turn has changed a file
      def undo(store:)
        return Undo::NOTHING if @entries.empty?

        entry = @entries.last
        Undo.of(entry, earlier: @entries[0...-1], pair: @pairs.fetch(entry.snapshot), store:,
                       remaining: @entries.size)
      end

      # Drops the latest turn without planning or making a move, so an undo
      # refused over something a human will not put back by hand does not
      # wedge every undo after it. The turn's changes stay on disk.
      #
      # @return [Skipped]
      # @raise [Moved] when there is no turn left to drop
      def skip
        raise Moved, "there is no file-changing turn left to skip" if @entries.empty?

        remaining = @entries.size
        entry = @entries.pop
        Skipped.new(turn: entry.turn, snapshot: entry.snapshot, remaining:)
      end

      # Marks the undo applied, so the next one walks further back.
      #
      # @raise [Moved] when a newer snapshot landed after `undo` was planned
      def undone(undo)
        raise Moved, "the undo planned for #{undo.turn} is no longer the latest turn's" \
          unless undo.snapshot == @entries.last&.snapshot

        @entries.pop
        self
      end

      private

      # A map repeating the one before is a rebound writer's duplicate, not a
      # turn's change -- unless the turn's trees moved, which no map can show.
      def keep(entry, pair)
        return if !pair.moved? && @entries.last&.files == entry.files

        @entries << entry
        @pairs[entry.snapshot] = pair
      end
    end

    class SnapshotLog
      # What undoing one turn would do: the moves to make, and the paths that
      # block it. An undo with any blocked path must not move at all.
      # `remaining` counts the turns still undoable, this one included: turns
      # already undone are not a human's to count.
      #
      # Reopened, rather than documented on the Data.define above, so the
      # constants and builders below land on Undo itself and YARD keeps this one
      # docstring.
      class Undo
        def self.of(entry, earlier:, pair:, store:, remaining:)
          moves, blocked = pair.staged? ? staged(entry, earlier, pair) : recorded(entry, earlier, store)
          new(turn: entry.turn, snapshot: entry.snapshot, scope: entry.scope, moves: moves.freeze,
              blocked: blocked.freeze, remaining:)
        end

        # The trees' own moves, and every write-set path the turn changed that
        # the trees never staged.
        def self.staged(entry, earlier, pair)
          unseen = changed(entry, earlier) - pair.keys
          [pair.moves, unseen.filter_map { |key| unseen_blocker(key, pair) }]
        end

        # A path the trees can see but did not list is one the turn left alone.
        def self.unseen_blocker(key, pair)
          return Revert::Blocker.new(key:, reason: :outside_root) if outside?(key)

          Revert::Blocker.new(key:, reason: :ignored) if pair.ignored?(key)
        end

        def self.recorded(entry, earlier, store)
          changed(entry, earlier).each_with_object([[], []]) do |key, (moves, blocked)|
            prior = prior(key, earlier)
            next_bytes = entry.files.fetch(key)
            if prior
              moves << Revert::Move.new(key:, before: side(store, prior), after: side(store, next_bytes))
            else
              blocked << Revert::Blocker.new(key:, reason: :unrecorded)
            end
          end
        end

        def self.changed(entry, earlier) = entry.files.keys.reject { |key| prior(key, earlier) == entry.files[key] }

        def self.prior(key, earlier) = earlier.reverse_each.find { |record| record.files.key?(key) }&.files&.fetch(key)

        def self.side(store, digest) = Revert::Side.new(bytes: store.fetch(digest).bytes, mode: nil)

        def self.outside?(key) = key.start_with?("/") || key == ".." || key.start_with?("../")

        private_class_method :staged, :unseen_blocker, :recorded, :changed, :prior, :side, :outside?

        def nothing? = snapshot.nil?

        def known? = blocked.empty?

        # The write-set scope never saw what a shell did, so an undo of its
        # snapshot restores only what lain's own tools wrote.
        def write_set? = scope == Snapshot::SCOPE_NOTE

        NOTHING = new(turn: nil, snapshot: nil, scope: nil, moves: [].freeze, blocked: [].freeze, remaining: 0)
      end
    end
  end
end
