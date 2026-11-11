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
    # order and at the head it was written at, so the list a chain restores is
    # the newest one written on that chain. A
    # {Telemetry::CompactionCut} folds into {Session#record_compaction_cut} in
    # recorded order too, which is how a resumed session renders a committed
    # cut's replacement byte for byte instead of asking a model for it again,
    # and does not fire a plan step a recorded commit already consumed. Each
    # spawn-less `turn_usage` adds to the count of the session's own answered
    # requests, {Session#requests_sent}. Every
    # cut is folded, the superseded ones included: which of them a chain
    # renders is the compaction source's question, and a rewind below a
    # collapse holds the cuts it re-wrote.
    #
    # The manifest is the session's project-memory VIEW: the `memory_loaded`
    # record naming the store version this chain opened on, the `memory_write`
    # turns recorded after it, and the `rewound` records that decide which of
    # them the chain still carries -- all of which
    # {Bench::Session::MemoryReplay} reconstructs a {Memory::Index} from, and
    # that index is what {Session}'s `memory:` wants.
    #
    # Every line is read once, through {Telemetry.read}, and the typed records
    # are folded once through the seven projections below; the raw records go to
    # the memory replay, which reads them as written. A record of ours that will
    # not rebuild refuses the resume as {Bench::Session::Corrupt}: a torn record
    # of our own is damage, where a foreign one comes back whole and is ignored.
    #
    # A record type with zero occurrences replays to that type's neutral state
    # (no reads, no todo reminder, an empty manifest) -- the tolerant
    # zero-record precedent {Bench::Session::MemoryReplay} itself sets.
    class Replay
      COMPACTION_CUT_TYPE = "compaction_cut"
      TODO_SNAPSHOT_TYPE = "todo_snapshot"

      # A private value satisfying {Session#write_todos}'s
      # `#content`/`#status` duck: {Tools::TodoWrite}'s own Item is
      # `private_constant`, so replay names its own rather than reach past
      # that boundary.
      Todo = Data.define(:content, :status)
      private_constant :Todo

      # The records a projection keeps, in the order they were folded, for a Session that must take
      # them in that order. A list of pairs, newest first, so a step shares the list it extends: an
      # Array copied per step is quadratic in a session's turns.
      class Log < Journal::Projection
        # @return [Log]
        def self.unit = new(nil)

        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [Log] self for a record this log does not keep
        def step(record) = keeps?(record) ? self.class.new([record, state]) : self

        # @return [Array<Telemetry::Journalable, Telemetry::Untyped>] oldest first
        def value
          Enumerator.produce(state, &:last).take_while(&:itself).map(&:first).reverse.freeze
        end
      end

      # What the model has seen of each file, and on which chain: the reads, the rounds the live
      # session withheld, and the turns and headers that deliver or withhold them.
      class Reads < Log
        BOUNDARIES = [SessionRecord::TURN_TYPE, SessionRecord::HEADER_TYPE].freeze

        private

        def keeps?(record)
          case record
          when Telemetry::SessionRead, Telemetry::SessionReadWithheld then true
          when Telemetry::Untyped then BOUNDARIES.include?(record["type"])
          else false
          end
        end
      end

      # Every list, each at the head it was written at.
      class Todos < Log
        private

        def keeps?(record) = record.is_a?(Telemetry::Untyped) && record["type"] == TODO_SNAPSHOT_TYPE
      end

      # Every committed cut, the superseded ones included, parent before child.
      class Cuts < Log
        private

        def keeps?(record) = record.is_a?(Telemetry::CompactionCut)
      end

      # The pinned digests: the stream is a log of transitions, so the last one for a digest wins.
      class Pins < Journal::Projection
        # @return [Pins]
        def self.unit = new({})

        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [Pins]
        def step(record)
          return self unless record.is_a?(Telemetry::SessionPin)

          self.class.new(record.pinned ? state.merge(record.digest => true) : state.except(record.digest))
        end

        # @return [Array<String>]
        def value = state.keys
      end

      # Each labeled turn's label, by digest; an empty label clears.
      class Labels < Journal::Projection
        # @return [Labels]
        def self.unit = new({})

        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [Labels]
        def step(record)
          return self unless record.is_a?(Telemetry::TurnLabeled)

          self.class.new(record.label.empty? ? state.except(record.digest) : state.merge(record.digest => record.label))
        end
      end

      # The latest re-entry note; an empty one clears it.
      class ReentryNote < Journal::Projection
        # @return [ReentryNote]
        def self.unit = new("")

        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [ReentryNote]
        def step(record) = record.is_a?(Telemetry::ReentryNote) ? self.class.new(record.note) : self

        # @return [String]
        def value = state
      end

      # A masked source replays from {Telemetry::SourceMasked}, NOT from a
      # `session_read` line, and that is the only shape available:
      # `record_read` by construction cannot reach the masked set, so a
      # `session_read` line would replay to a read and quietly permit the write
      # that a mask exists to refuse. Both are add-only, so order against the reads does not matter.
      class WithheldSources < Journal::Projection
        # @return [WithheldSources]
        def self.unit = new({})

        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [WithheldSources]
        def step(record)
          return self unless record.is_a?(Telemetry::SourceMasked)

          self.class.new(state.merge(Session::Withheld::Source.new(kind: record.kind, key: record.key) => true))
        end

        # @return [Array<Session::Withheld::Source>]
        def value = state.keys
      end

      PROJECTIONS = { reads: Reads, pins: Pins, labels: Labels, reentry_note: ReentryNote, todos: Todos, cuts: Cuts,
                      withheld: WithheldSources }.freeze
      private_constant :PROJECTIONS

      # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck, walked once -- a
      #   String is one raw NDJSON line, a Hash is already parsed; a line that does not parse
      #   is somebody else's and skipped
      # @raise [Bench::Session::Corrupt] for a record of our own that will not rebuild
      def initialize(entries)
        @records = Journal.records(entries).to_a.freeze
        @folded = Journal::Projections.of(**PROJECTIONS.transform_values(&:unit))
                                      .over(@records.each_with_index.lazy.map { |record, index| typed(record, index) })
      end

      # The recorded memory view is attached last: placing the todo lists on
      # `on` moves the Session along that chain, and the view is already the
      # chain's own fold, which a second follow would re-derive differently.
      #
      # @param on [Ext::Timeline] the chain the resumed run stands on; its todo
      #   list is the newest one written on it
      # @return [Session] a fresh Session carrying the recorded read-set, the
      #   pin-set the recorded transitions fold to, the turn labels, the todo list, every
      #   committed compaction cut, the count of the session's own answered requests,
      #   and the manifest reminders the recorded memory chain reconstructs
      def session(on:)
        Session.new.tap do |fresh|
          restore_reads(fresh)
          restore_pins(fresh)
          restore_labels(fresh)
          restore_reentry_note(fresh)
          restore_todos(fresh, on)
          restore_cuts(fresh)
          restore_requests(fresh)
        end.watch_memory(memory)
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
        @memory ||= built_from(Bench::Session::MemoryReplay.new(records: @records))
      end

      private

      def typed(record, index)
        Telemetry.read(record)
      rescue Telemetry::Unreadable => e
        raise Bench::Session::Corrupt, "record #{index} of the resume chain, counting from 0#{naming(record)}, " \
                                       "cannot be rebuilt: #{e.message}"
      end

      def naming(record) = record.key?("path") ? " (#{record["path"].inspect})" : ""

      def projected(key) = @folded[key].value

      # The SEED rides along, not just the folded index: a caller holding a
      # chain shorter than the recorded one -- a `/fork` below a memory_write --
      # re-folds through {Memory::Recorder#follow}, and a recorder that had
      # forgotten what it opened on would reseed from nothing and drop every
      # item the session inherited.
      def built_from(replay)
        Memory::Recorder.new(index: replay.recorded_memory.index, loaded: replay.loaded)
      end

      # A read binds to the first turn after it whose parent is the head its
      # round opened on and whose results answer its call -- the pair a live
      # session binds by, so a reused call id, a repair written late or a file
      # boundary cannot move a read onto another round's turn. A read no
      # recorded turn answers belongs to a round torn before its results
      # landed, and is withheld: where the live session recorded withholding it,
      # at the end of the record, and at each session header a resume chain
      # carries, since no later process delivers an earlier one's round.
      def restore_reads(fresh)
        projected(:reads).each { |record| restore_read(fresh, record) }
        fresh.withhold_undelivered
        # A known limit: a child's guard journals into this same record, and
        # nothing on a mask says whose read it was, so a child's masked read
        # resumes as the parent's. It fails closed -- the parent is refused a
        # write over a file the child saw masked.
        projected(:withheld).each { |source| fresh.record_withheld(source) }
      end

      def restore_read(fresh, record)
        case record
        when Telemetry::SessionRead then fresh.record_read(record.path, **read_fields(record))
        when Telemetry::SessionReadWithheld then fresh.withhold_rounds(record.rounds)
        else restore_boundary(fresh, record)
        end
      end

      def restore_boundary(fresh, record)
        return fresh.withhold_undelivered unless record["type"] == SessionRecord::TURN_TYPE

        fresh.record_delivery(**%w[digest parent content].to_h { |key| [key.to_sym, record.fields.fetch(key)] })
      end

      def read_fields(read)
        { lines: read.lines.first..read.lines.last, tool_use_id: read.tool_use_id, head: read.head,
          identity: Session::FileIdentity.new(**read.identity.to_h { |key, value| [key.to_sym, value] }) }
      end

      def restore_pins(fresh) = projected(:pins).each { |digest| fresh.record_pin(digest) }

      def restore_reentry_note(fresh)
        note = projected(:reentry_note)
        fresh.record_reentry_note(note) unless note.empty?
      end

      def restore_labels(fresh) = projected(:labels).each { |digest, label| fresh.record_label(digest, label) }

      # Every list is written again at the head it was recorded at, so a later
      # rewind finds each list where the live session held it.
      def restore_todos(fresh, chain)
        projected(:todos).each { |record| fresh.on_chain(placed_on(chain, headed(record))).write_todos(items(record)) }
        fresh.rewound_to(chain)
      end

      def placed_on(chain, head)
        raise Bench::Session::Corrupt, unwritten_head(head) unless Telemetry::TodoSnapshot.writable_head?(head)

        chain.checkout(head)
      rescue Ext::Store::MissingObject
        raise Bench::Session::Corrupt, unwritten_head(head)
      end

      def unwritten_head(head)
        "a todo_snapshot record names head #{head.inspect}, which this session record never wrote"
      end

      def headed(record)
        record.fields.fetch("head") { raise Bench::Session::Corrupt, "a todo_snapshot record carries no head" }
      end

      def items(record)
        record.fields.fetch("todos").map do |todo|
          Todo.new(content: todo.fetch("content"), status: todo.fetch("status"))
        end
      end

      # Recorded order puts every parent ahead of its child, and the Session
      # refuses a child whose parent it has not folded -- so a truncated record
      # fails here, loudly, instead of resuming onto a seam with a hole in it.
      # As {Bench::Session::Corrupt}, because that is the damage it is, and the
      # refusal resume and fork already turn into "cannot resume <file>".
      def restore_cuts(fresh)
        projected(:cuts).each do |cut|
          superseded(fresh, cut)
          fresh.record_compaction_cut(cut)
        end
      rescue Session::UnrecordedParent => e
        raise Bench::Session::Corrupt, "the compaction_cut record chain is incomplete: #{e.message}; " \
                                       "a cut's parent record is missing from the session file"
      end

      def restore_requests(fresh)
        sent = @records.count { _1["type"] == "turn_usage" && _1["spawn"].nil? && Telemetry::TurnUsage.agent?(_1) }
        sent.times { fresh.record_request }
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
    end
  end
end
