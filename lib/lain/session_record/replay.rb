# frozen_string_literal: true

module Lain
  module SessionRecord
    # Rebuilds a fresh {Session}'s run-state from a session record -- the
    # read side of {Session::Journaled} and {Tools::TodoWrite}: a
    # {Telemetry::SessionRead} folds straight into {Session#record_read}, and
    # a {Telemetry::TodoSnapshot} folds into {Session#write_todos} in
    # RECORDED order, so its own replace-not-merge semantics do the rest --
    # folding N snapshots and keeping only the last one's effect is exactly
    # what one direct call already does, applied N times.
    #
    # The manifest needs no third record type (T16's card, AC2): a run's
    # `turn` / `memory_root` chain is already exactly what
    # {Bench::Session::MemoryReplay} reconstructs a {Memory::Index} from, and
    # that index is exactly what {Session}'s `memory:` wants. The reference
    # to `Bench::Session::MemoryReplay` sits inside a method body, resolved
    # at CALL time -- the same lazy cross-unit reach {Session}'s OWN
    # `memory: Memory::Recorder.new` default already makes from #21 in
    # `lain.rb`'s load order to Memory at #40, well before either runs.
    #
    # A record type with zero occurrences replays to that type's neutral
    # state (no reads, no todo reminder, an empty manifest) -- the same
    # tolerant zero-record precedent {Bench::Session::MemoryReplay} itself
    # already sets for a `memory_root`-free chain.
    class Replay
      SESSION_READ_TYPE = "session_read"
      TODO_SNAPSHOT_TYPE = "todo_snapshot"
      MEMORY_ROOT_TYPE = "memory_root"

      # A private value satisfying {Session#write_todos}'s
      # `#content`/`#status` duck: {Tools::TodoWrite}'s own Item is
      # `private_constant`, so replay names its own rather than reach past
      # that boundary.
      Todo = Data.define(:content, :status)
      private_constant :Todo

      # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck --
      #   a String is one raw NDJSON line, a Hash is already-parsed; foreign
      #   entries (somebody else's records) are skipped, not raised on
      def initialize(entries)
        @records = entries.to_a
      end

      # @return [Session] a fresh Session carrying the recorded read-set, the
      #   LAST recorded todo list, and the manifest reminders the recorded
      #   memory chain reconstructs
      def session
        Session.new(memory:).tap do |fresh|
          reads.each { |record| fresh.record_read(record.fetch("path")) }
          todo_records.each { |record| fresh.write_todos(items(record)) }
        end
      end

      private

      def reads
        Journal.records(@records, type: SESSION_READ_TYPE)
      end

      def todo_records
        Journal.records(@records, type: TODO_SNAPSHOT_TYPE)
      end

      def items(record)
        record.fetch("todos").map { |todo| Todo.new(content: todo.fetch("content"), status: todo.fetch("status")) }
      end

      def memory
        Memory::Recorder.new(index: Bench::Session::MemoryReplay.new(turns:, roots:).recorded_memory.index)
      end

      def turns
        Journal.records(@records, type: SessionRecord::TURN_TYPE).to_a
      end

      def roots
        Journal.records(@records, type: MEMORY_ROOT_TYPE).to_a
      end
    end
  end
end
