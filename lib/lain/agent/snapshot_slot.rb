# frozen_string_literal: true

require "securerandom"

module Lain
  class Agent
    # Where a turn's snapshot writer lives, so the writer can change under a
    # {ToolDelivery} that is built once and never rebuilt. The delivery primes
    # it before a turn's tools run and writes through it when they settle; a
    # `/mode` flip into or out of plan scope rebinds it at the scope's root.
    #
    # Every prime restages the scope's before-tree, and every write records
    # the snapshot in the {#log} with the turn's tree pair, so an undo of a
    # shadow turn reverts exactly what that turn changed.
    #
    # A shadow store that fails costs one turn its shadow record, never its
    # answers: the failure is journaled, that turn is recorded as the write-set
    # scope records one, and the next prime tries the store again. Raising
    # instead would leave every tool call of the turn unanswered.
    #
    # This is also the only object on the snapshot path that can say anything
    # out loud, so the two ways a turn's changes end up irreversible are both
    # announced from here: a store that failed, and a write the snapshot's root
    # does not reach. {Workspace::Snapshot} cannot -- nothing there journals.
    #
    # The writer is built on the first {#prime}, not at construction, so a
    # chat that never calls a tool never pays for a shadow baseline or touches
    # the state home.
    class SnapshotSlot
      # A read of a slot no turn has primed. Loud rather than nil: every reader
      # below answers about a bound snapshot, and nil would be a second meaning.
      class NotBound < Error; end

      # One turn whose shadow store failed, and why.
      SnapshotDegraded = Data.define(:phase, :scope, :reason) do
        include ::Lain::Telemetry::Journalable
      end

      # One turn whose scope refused paths for falling outside the snapshot's
      # root: how many, under which scope and root. The count, not the paths,
      # because the session's write set is cumulative and repeats the same ones
      # every turn after a scope flip -- what a reader needs is that this turn's
      # undo reaches less than the session wrote.
      SnapshotNarrowed = Data.define(:scope, :root, :dropped) do
        include ::Lain::Telemetry::Journalable
      end

      # Git that did not answer, or a state home that cannot be made.
      DEGRADABLE = [Workspace::Snapshot::Scope::ShadowGit::Failed, Paths::Unwritable].freeze

      # What a board holds before the agent build binds it a slot: a flip moves
      # nothing, and reading the snapshots refuses by name rather than
      # answering as an empty history.
      module Unbound
        REFUSAL = "no snapshot slot is bound to this board; the agent build binds one when it builds the Agent"

        def self.rebind(_scope = nil, **) = self

        def self.log = raise(NotBound, REFUSAL)

        def self.root = raise(NotBound, REFUSAL)
      end

      attr_reader :root, :log

      # @param root [String] where every writer this slot builds is rooted
      # @param scope [Symbol, #note] the starting scope, by name or built
      # @param log [Workspace::SnapshotLog] records every writer's snapshots,
      #   across rebinds
      # @param paths [Paths] the state home a shadow scope keeps its store in
      # @param journal [#<<] where a degraded or narrowed turn is recorded
      # @param channel [#<<] where the human is told of one: the chat's live
      #   Channel, since the journal is the experiment's record, not a screen
      def initialize(root: Dir.pwd, scope: :write_set, log: Workspace::SnapshotLog.new, paths: Paths.new,
                     journal: Channel::Null.instance, channel: Channel::Null.instance)
        @root = File.expand_path(root).freeze
        @log = log
        @paths = paths
        @journal = journal
        @channel = channel
        @session = SecureRandom.hex(6)
        @scope = resolve(scope)
      end

      def label = @scope.label

      # @return [self]
      def prime
        @degraded = false
        @writer ? @writer.prime : @writer = built
        self
      rescue *DEGRADABLE => e
        degrade(:prime, e)
      end

      # The writer duck, so {ToolDelivery} holds one object either way.
      # `pre_images:` is what the turn's tools captured before their first
      # writes, handed to the log beside the snapshot and never written into it.
      def write(timeline:, paths:, pre_images: {})
        prime unless @writer || @degraded
        land(@degraded ? fallback : @writer, timeline:, paths:, pre_images:)
      rescue *DEGRADABLE => e
        degrade(:settle, e)
        land(fallback, timeline:, paths:, pre_images:)
      end

      # After an undo moved disk back: the log forgets the turn, and every
      # writer is told what the undo left on disk, so a turn that makes the
      # undone change again lands a snapshot rather than matching stale memory.
      # Not the earlier record's map: a restored pre-image can differ from it,
      # and a writer resumed from it would take the next turn for that change.
      #
      # @return [self]
      def undone(undo)
        @log.undone(undo)
        [@writer, @fallback].compact.each { |writer| writer.resume(undo.left) }
        self
      end

      # Drops the latest turn without restoring anything. Disk is exactly as
      # that turn left it, so the writers' memory is still true.
      #
      # @return [Workspace::SnapshotLog::Skipped]
      def skip = @log.skip

      # A flip that moves neither the scope nor the root keeps the writer: a
      # fresh one remembers nothing, so it would land a duplicate of the last
      # snapshot and take a new shadow baseline for no change at all. A writer
      # not yet built stays unbuilt. A new root is where plan scope moves the
      # session's writes, so the write-set fallback moves with it.
      #
      # @param scope [Symbol, #note] by name or built; the one in force by default
      # @param root [String] where the next writer is rooted; this slot's by default
      # @return [self]
      def rebind(scope = @scope, root: @root)
        candidate = resolve(scope)
        expanded = File.expand_path(root).freeze
        return self if candidate.label == label && expanded == @root

        @scope = candidate
        @root = expanded
        @fallback = nil
        @writer &&= built
        self
      end

      private

      def land(writer, timeline:, paths:, pre_images:)
        event = writer.write(timeline:, paths:) || rewritten(writer, timeline:, paths:, pre_images:)
        @log.record(event, pair: writer.pair, pre_images:) if event
        narrowed(writer)
        event
      end

      # The journal takes every turn's record; the human hears each distinct
      # narrowing once. A turn that dropped nothing says nothing.
      def narrowed(writer)
        dropped = writer.outside
        told(SnapshotNarrowed.new(scope: label, root: @root, dropped: dropped.size)) unless dropped.empty?
      end

      # The session's write set is cumulative, so the same paths are dropped
      # again every turn after; a line per turn would scribble the pane it is
      # meant to inform, and silence let `/undo` report "no file needed putting
      # back" over a file that is still changed. So the record repeats in the
      # journal, which is the experiment's, and the channel hears it when the
      # scope, the root or the count changes -- the record's own equality.
      def told(record)
        @journal << record
        return if @told == record

        @told = record
        @channel << record
      end

      # A writer matches its map against its memory, and a turn that wrote a
      # human's edit back to the bytes lain last recorded repeats that map. The
      # pre-images show the change, so the writer forgets and writes again.
      def rewritten(writer, timeline:, paths:, pre_images:)
        writer.resume(nil).write(timeline:, paths:) if pre_images.any? { |path, image| image.replaced?(path) }
      end

      def degrade(phase, error)
        @degraded = true
        SnapshotDegraded.new(phase:, scope: label, reason: error.message).tap do |degraded|
          @journal << degraded
          @channel << degraded
        end
        self
      end

      def fallback = @fallback ||= Workspace::Snapshot.new(root: @root, scope: :write_set)

      # One session for every scope this slot builds, so a rebind keeps
      # staging through the same index in the shared store.
      def resolve(scope) = Workspace::Snapshot::Scope.resolve(scope, paths: @paths, session: @session)

      def built = Workspace::Snapshot.new(root: @root, scope: @scope)
    end
  end
end
