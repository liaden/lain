# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Event-sources the {RecordedMemory} surface from the turn records
      # themselves: successful memory_write tool_use inputs ARE the write log,
      # so a fresh {Memory::Index} replaying them lands on the same roots the
      # live run produced -- content addressing makes byte-equality against
      # the journaled memory_root chain the integrity proof, the Loader's
      # verify-by-recommit idiom applied to memory. A write whose paired
      # tool_result is an error (refused or failed) never reached the live
      # recorder, so it must not enter the replay either.
      #
      # A journal with ZERO memory_root records replays its writes unverified
      # -- the tolerant pre-decorator precedent, like the header's
      # `extra || {}`. A PARTIAL chain is different: memory_root records are
      # not Merkle-anchored, so a silently deleted line is otherwise
      # undetectable, and some records with incomplete coverage of the
      # write-bearing turns raises {Corrupt}. Stated honestly: coverage is
      # checked only for WRITE-BEARING turns, so deleting the record paired
      # with a write-free turn still loads clean -- the envelope detects
      # deletions that could hide a write, not every deletion.
      class MemoryReplay
        def initialize(turns:, roots:)
          @turns = turns
          @roots = roots
        end

        # @return [RecordedMemory]
        # @raise [Corrupt] on a root disagreeing with the replay, a record
        #   naming no recorded turn, or a partial chain
        def recorded_memory
          verified(replayed)
        end

        private

        # The pre-write pairing pinned by the memory-snapshot seam spec: a
        # turn's root is snapshotted BEFORE its own writes apply, because
        # TurnUsage (which the memory_root record pairs with) journals after
        # the assistant commit and strictly before perform_tools.
        def replayed
          index = Memory::Index.empty
          roots = write_calls.to_h do |record, calls|
            snapshot = index.root
            index = writes(calls).inject(index) { |replay, item| replay.write(item) }
            [record.fetch("digest"), snapshot]
          end
          RecordedMemory.new(roots:, index:)
        end

        def writes(calls)
          calls.map do |block|
            input = block.fetch("input")
            Memory::Item.new(id: input.fetch("id"), description: input.fetch("description"),
                             body: input.fetch("body"))
          end
        end

        # Every turn paired with the write calls that replay, selected ONCE for
        # the whole pass: the fold ({#replayed}) and the coverage envelope
        # ({#write_bearing}) read the same blocks out of the same records, and
        # re-selecting per reader re-scanned every turn's content twice.
        #
        # An Array of pairs, NOT a digest-keyed Hash: a rewound session
        # journals the same turn digest more than once by design (the scribe
        # re-records the chain after each `rewound`, and
        # {SessionRecord::Replay#turns} hands those straight here), so keying
        # by digest would drop an occurrence's writes and under-report
        # {#write_bearing} -- a wrong count, reported silently. Pairs also keep
        # {#writes} free of any membership precondition.
        def write_calls
          @write_calls ||= @turns.map { |record| [record, replayable(record)] }
        end

        # `== false`, not negation: a tool_use with no recorded result (nil)
        # never executed, so it must not replay any more than an errored one.
        def replayable(record)
          blocks(record).select do |block|
            block["type"] == "tool_use" && block["name"] == "memory_write" && outcomes[block["id"]] == false
          end
        end

        def blocks(record)
          content = record.fetch("content")
          content.is_a?(Array) ? content.grep(Hash) : []
        end

        # tool_use_id => is_error, across the whole chain: results answer
        # their tool_use from the FOLLOWING user turn, and ids are unique per
        # run, so one flat map is the pairing.
        def outcomes
          @outcomes ||= @turns.flat_map { |record| blocks(record) }
                              .select { |block| block["type"] == "tool_result" }
                              .to_h { |block| [block["tool_use_id"], block["is_error"]] }
        end

        def verified(memory)
          return memory if @roots.empty?

          covered!
          @roots.each { |record| agree!(record, memory) }
          memory
        end

        def covered!
          missing = write_bearing - @roots.map { |record| record.fetch("turn_digest") }
          return if missing.empty?

          raise Corrupt, "no memory_root record pairs write-bearing turn(s) " \
                         "#{missing.join(", ")}; a partial chain reads as deletion, not as a " \
                         "pre-decorator recording"
        end

        def write_bearing
          write_calls.select { |_record, calls| calls.any? }.map { |record, _calls| record.fetch("digest") }
        end

        def agree!(record, memory)
          turn_digest = record.fetch("turn_digest")
          replayed = memory.roots.fetch(turn_digest) do
            raise Corrupt, "memory_root record names turn #{turn_digest}, which is not in the turn chain"
          end
          return if replayed == record.fetch("root")

          raise Corrupt, "memory_root for turn #{turn_digest} recorded as #{record.fetch("root").inspect} " \
                         "but the recorded writes replay to #{replayed.inspect}; the record no longer " \
                         "matches its turns"
        end
      end
    end
  end
end
