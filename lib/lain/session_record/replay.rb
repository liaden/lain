# frozen_string_literal: true

module Lain
  module SessionRecord
    # Rebuilds a fresh {Session}'s run-state from a session record -- the read
    # side of {Session}'s own journaling and {Tools::TodoWrite}. The Session it
    # builds carries NO journal, or folding the record would re-journal every
    # line it just read; {CLI::Chronicle#wrap_session} attaches the new run's
    # journal afterwards. A
    # {Telemetry::SessionRead} folds into {Session#record_read} carrying its
    # span, file version and call, and each recorded turn's results bind the
    # calls they answer, in recorded order -- so a read counts on a resumed
    # chain exactly when the turn that delivered it is on that chain. A
    # {Telemetry::TodoSnapshot} folds into {Session#write_todos} in RECORDED
    # order, so its replace-not-merge semantics do the rest. A
    # {Telemetry::CompactionCut} folds into {Session#record_compaction_cut} in
    # recorded order too, which is how a resumed session renders a committed
    # cut's replacement byte for byte instead of asking a model for it again,
    # and does not fire a plan step a recorded commit already consumed. Every
    # cut is folded, the superseded ones included: which of them a chain
    # renders is the compaction source's question, and a rewind below a
    # collapse holds the cuts it re-wrote.
    #
    # The manifest is the session's project-memory VIEW: the `memory_loaded`
    # record naming the store version this chain opened on, the `memory_write`
    # turns recorded after it, and the `rewound` records that decide which of
    # them the chain still carries -- all of which
    # {Bench::Session::MemoryReplay} reconstructs a {Memory::Index} from, and
    # that index is what {Session}'s `memory:` wants. That constant is reached
    # inside a method body, resolved at CALL time -- the same lazy cross-unit
    # reach {Session}'s own `memory:` default already makes from #21 in
    # `lain.rb`'s load order to Memory at #40.
    #
    # A record type with zero occurrences replays to that type's neutral state
    # (no reads, no todo reminder, an empty manifest) -- the tolerant
    # zero-record precedent {Bench::Session::MemoryReplay} itself sets.
    class Replay
      SESSION_READ_TYPE = "session_read"
      SESSION_READ_WITHHELD_TYPE = "session_read_withheld"
      READ_REDACTED_TYPE = "read_redacted"
      SESSION_PIN_TYPE = "session_pin"
      TODO_SNAPSHOT_TYPE = "todo_snapshot"
      COMPACTION_CUT_TYPE = "compaction_cut"
      CUT_FIELDS = Telemetry::CompactionCut.members.freeze
      READ_FIELDS = Telemetry::SessionRead.members.map(&:to_s).freeze
      private_constant :CUT_FIELDS, :READ_FIELDS

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
      #   pin-set the recorded transitions fold to, the LAST recorded todo
      #   list, every committed compaction cut, and the manifest reminders the
      #   recorded memory chain reconstructs
      def session
        Session.new(memory:).tap do |fresh|
          restore_reads(fresh)
          restore_pins(fresh)
          restore_todos(fresh)
          restore_cuts(fresh)
        end
      end

      # The ONE recorder {#session}'s manifest projects from -- public and
      # memoized so a resume can hand the SAME object to the memory
      # tools ("one index, three views"); a second recorder here would give
      # the manifest and the tools silently divergent indexes.
      #
      # The whole record array goes in, in file order: the seed this chain's
      # newest `memory_loaded` names, the writes recorded after it and the head
      # moves that decide which of them the chain still carries are readable
      # only together. It carries NO store -- this is the recorded view, and
      # {Memory::ProjectStore#resumed} is what binds it to the project's store
      # for the run that resumes it.
      #
      # @return [Memory::Recorder]
      def memory
        @memory ||= built_from(Bench::Session::MemoryReplay.new(records: Journal.records(@records)))
      end

      private

      # The SEED rides along, not just the folded index: a caller holding a
      # chain shorter than the recorded one -- a `/fork` below a memory_write --
      # re-folds through {Memory::Recorder#follow}, and a recorder that had
      # forgotten what it opened on would reseed from nothing and drop every
      # item the session inherited.
      def built_from(replay)
        Memory::Recorder.new(index: replay.recorded_memory.index, loaded: replay.loaded)
      end

      # The read-set is THREE record types, folded together here because they
      # rebuild one thing: what the model has seen of each file, and on which
      # chain.
      #
      # A read binds to the first turn after it whose parent is the head its
      # round opened on and whose results answer its call -- the pair a live
      # session binds by, so a reused call id, a repair written late or a file
      # boundary cannot move a read onto another round's turn. A read no
      # recorded turn answers belongs to a round torn before its results
      # landed, and is withheld: where the live session recorded withholding it,
      # at the end of the record, and at each session header a resume chain
      # carries, since no later process delivers an earlier one's round.
      #
      # A record this cannot rebuild -- one written before reads carried spans,
      # or a damaged one -- refuses the resume as {Bench::Session::Corrupt},
      # which both doors turn into "cannot resume <file>".
      def restore_reads(fresh)
        Journal.records(@records).each { |record| restore_read(fresh, record) }
        fresh.withhold_undelivered
        # A known limit: a child's guard journals into this same record, and
        # nothing on a mask says whose read it was, so a child's masked read
        # resumes as the parent's. It fails closed -- the parent is refused a
        # write over a file the child saw masked.
        redactions.each { |record| fresh.record_masked_read(record.fetch("path")) }
      end

      def restore_read(fresh, record)
        case record["type"]
        when SESSION_READ_TYPE then fresh.record_read(record.fetch("path"), **read_fields(record))
        when SESSION_READ_WITHHELD_TYPE then fresh.withhold_rounds(withheld_rounds(record))
        when SessionRecord::TURN_TYPE then fresh.record_delivery(**delivery_fields(record))
        when SessionRecord::HEADER_TYPE then fresh.withhold_undelivered
        end
      end

      def withheld_rounds(record)
        Telemetry::SessionReadWithheld.new(rounds: record.fetch("rounds")).rounds
      rescue KeyError, ArgumentError => e
        raise Bench::Session::Corrupt, "a session_read_withheld record cannot be rebuilt (#{e.message})"
      end

      def delivery_fields(record)
        { digest: record.fetch("digest"), parent: record.fetch("parent"), content: record.fetch("content") }
      end

      def restore_pins(fresh) = pins.each { |record| apply_pin(fresh, record) }

      def restore_todos(fresh) = todo_records.each { |record| fresh.write_todos(items(record)) }

      # Recorded order puts every parent ahead of its child, and the Session
      # refuses a child whose parent it has not folded -- so a truncated record
      # fails here, loudly, instead of resuming onto a seam with a hole in it.
      # As {Bench::Session::Corrupt}, because that is the damage it is, and the
      # refusal resume and fork already turn into "cannot resume <file>".
      def restore_cuts(fresh)
        Journal.records(@records, type: COMPACTION_CUT_TYPE).each do |record|
          cut = Telemetry::CompactionCut.new(**cut_fields(record))
          superseded(fresh, cut)
          fresh.record_compaction_cut(cut)
        end
      rescue Session::UnrecordedParent => e
        raise Bench::Session::Corrupt, "the compaction_cut record chain is incomplete: #{e.message}; " \
                                       "a cut's parent record is missing from the session file"
      end

      # A collapse carries the seam it re-wrote and names the cuts whose ranges
      # it replaces, which a chain below its commit head still holds. One of
      # those missing is the same damage a missing parent is -- the record
      # would fold to a session rendering ranges twice -- so it is refused
      # here, where the fold happens.
      def superseded(fresh, cut)
        cut.supersedes.each do |address|
          fresh.compaction_cut(address)
        rescue KeyError
          raise Bench::Session::Corrupt, "the compaction_cut at #{cut.digest} supersedes #{address}, which is " \
                                         "not a cut this session record holds"
        end
      end

      def cut_fields(record)
        CUT_FIELDS.to_h { |field| [field, record.fetch(field.to_s)] }
      end

      # A masked read replays from {Telemetry::ReadRedacted}, NOT from a
      # `session_read` line, and that is the only shape available:
      # `record_read` by construction cannot reach the masked set, so a
      # `session_read` line would replay to a read and quietly permit the write
      # that a mask exists to refuse. `read_redacted` already names the path, is
      # already written by {Middleware::RedactSecretReads} into this same
      # journal, and needs no new field.
      #
      # Order against the reads does not matter: both are add-only and
      # {Session#record_masked_read} is idempotent, so a redaction folded before
      # or after its own `session_read` lands on the same state.
      def redactions
        Journal.records(@records, type: READ_REDACTED_TYPE)
      end

      # Every field is fetched, and the span is rebuilt through the writer's
      # own guard: a salvaged or hand-edited journal is exactly what these
      # records must survive, and a span read loosely rebuilds as more of the
      # file than the model saw. Loud beats plausible.
      def read_fields(record)
        settled = Telemetry::SessionRead.new(**READ_FIELDS.to_h { |field| [field.to_sym, record.fetch(field)] })
        { lines: settled.lines.first..settled.lines.last, tool_use_id: settled.tool_use_id, head: settled.head,
          identity: Session::FileIdentity.new(**settled.identity.to_h { |key, value| [key.to_sym, value] }) }
      rescue KeyError, ArgumentError => e
        raise Bench::Session::Corrupt, "a session_read record for #{record["path"].inspect} cannot be rebuilt " \
                                       "(#{e.message}); a record written before reads carried line spans, " \
                                       "or a damaged one, cannot say what the model saw of the file"
      end

      def pins
        Journal.records(@records, type: SESSION_PIN_TYPE)
      end

      # RECORDED ORDER is the whole contract: a `session_pin` stream is an
      # ordered log of transitions, so folding it in file order makes the last
      # transition for a digest win -- which is how a pin-then-unpin rebuilds
      # as NOT pinned rather than as a stale pin nothing can retract.
      #
      # The direction is read as a STRICT boolean, matching what
      # {Telemetry::Carriers::SessionPin} enforces on the way out. Folding by
      # truthiness instead would trust more than the writer ever promised:
      # `"pinned": "false"` would rebuild as PINNED and `null` as an unpin, and
      # a salvaged or hand-edited journal is exactly the input this record type
      # exists to survive. Loud beats plausible.
      def apply_pin(fresh, record)
        digest = record.fetch("digest")
        direction = record.fetch("pinned")
        unless [true, false].include?(direction)
          raise Error, "session_pin for #{digest.inspect} must carry pinned true or false, " \
                       "got #{direction.inspect}"
        end

        direction ? fresh.record_pin(digest) : fresh.record_unpin(digest)
      end

      def todo_records
        Journal.records(@records, type: TODO_SNAPSHOT_TYPE)
      end

      def items(record)
        record.fetch("todos").map { |todo| Todo.new(content: todo.fetch("content"), status: todo.fetch("status")) }
      end
    end
  end
end
