# frozen_string_literal: true

require "securerandom"

module Lain
  class Agent
    # Where a turn's snapshot writer lives, so the writer can change under a
    # {ToolDelivery} that is built once and never rebuilt. The delivery primes
    # it before a turn's tools run and writes through it when they settle; a
    # `/mode` flip rebinds it through {CLI::Switchboard#apply}, which is what
    # puts the posture's declared scope in force.
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

      # Git that did not answer, or a state home that cannot be made.
      DEGRADABLE = [Workspace::Snapshot::Scope::ShadowGit::Failed, Paths::Unwritable].freeze

      # What a board holds before the agent build binds it a slot: a flip moves
      # nothing, and reading the snapshots refuses by name rather than
      # answering as an empty history.
      module Unbound
        REFUSAL = "no snapshot slot is bound to this board; the agent build binds one when it builds the Agent"

        def self.rebind(_scope) = self

        def self.log = raise(NotBound, REFUSAL)

        def self.root = raise(NotBound, REFUSAL)
      end

      attr_reader :root, :log

      # @param root [String] where every writer this slot builds is rooted
      # @param scope [Symbol, #note] the starting scope, by name or built
      # @param log [Workspace::SnapshotLog] records every writer's snapshots,
      #   across rebinds
      # @param paths [Paths] the state home a shadow scope keeps its store in
      # @param journal [#<<] where a degraded turn is recorded
      # @param channel [#<<] where the human is told of one: the chat's live
      #   Channel, since the journal is the experiment's record, not a screen
      def initialize(root: Dir.pwd, scope: :write_set, log: Workspace::SnapshotLog.new, paths: Paths.new,
                     journal: Channel::Null.instance, channel: Channel::Null.instance)
        @root = File.expand_path(root)
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
      def write(timeline:, paths:)
        prime unless @writer || @degraded
        land(@degraded ? fallback : @writer, timeline:, paths:)
      rescue *DEGRADABLE => e
        degrade(:settle, e)
        land(fallback, timeline:, paths:)
      end

      # After an undo moved disk back: the log forgets the turn, and every
      # writer is told what disk holds now, so a turn that makes the undone
      # change again lands a snapshot rather than matching stale memory.
      #
      # @return [self]
      def undone(undo)
        @log.undone(undo)
        [@writer, @fallback].compact.each { |writer| writer.resume(@log.to_a.last&.files) }
        self
      end

      # Drops the latest turn without restoring anything. Disk is exactly as
      # that turn left it, so the writers' memory is still true.
      #
      # @return [Workspace::SnapshotLog::Skipped]
      def skip = @log.skip

      # A same-scope flip keeps the writer: a fresh one remembers nothing, so
      # it would land a duplicate of the last snapshot and take a new shadow
      # baseline for no change at all. A writer not yet built stays unbuilt.
      #
      # @return [self]
      def rebind(scope)
        candidate = resolve(scope)
        return self if candidate.label == label

        @scope = candidate
        @writer &&= built
        self
      end

      private

      def land(writer, timeline:, paths:)
        writer.write(timeline:, paths:).tap { |event| @log.record(event, pair: writer.pair) if event }
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
