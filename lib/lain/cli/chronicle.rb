# frozen_string_literal: true

module Lain
  module CLI
    # The durable session record's lifecycle for one chat run, lifted out of the
    # thin Thor executable the way {Backend} lifted provider resolution: the exe
    # wires collaborators together; this object owns WHEN the journal opens,
    # what the scribe's header pins, which journal telemetry lands in, and how
    # the record closes.
    #
    # Two-phase by necessity: the tools need {#observer} at construction, but
    # the scribe's header pins the FINISHED toolset -- so construction opens
    # the journal, and {#start} (once the toolset exists) writes the header.
    # Anything that needs the scribe earlier raises {NotStarted} loudly: the
    # pre-start window is wiring time, when no event can flow, and a silently
    # swallowed early event would be record loss.
    class Chronicle
      class NotStarted < Error; end

      # The same duck with no record behind it (--no-journal): every message
      # answers, nothing lands, so the exe carries no nil-checks
      # ({Sink::Null}'s idiom). `tee:` still carries the --nvim telemetry leg,
      # which exists independently of the session record. The `(**)`
      # signatures accept the real methods' keywords without naming arguments
      # a Null never reads.
      class Null
        def initialize(tee: nil)
          @tee = tee
        end

        def observer = Event::ChainWriter::Null.new
        def start(**) = self
        def wrap_session(session) = session
        def wrap_memory(recorder) = recorder
        def turn_middleware(_timeline) = Middleware::Stack.new
        def telemetry_kwargs = Chronicle.telemetry_kwargs(@tee)
        def catch_up(_timeline) = self
        def interrupted(**) = self
        def close(**) = self

        # --no-journal's answer to {Chronicle#spool}: the same Null spool
        # {Provider::AnthropicRaw} already defaults to, so a provider built
        # with it opens no `.wal` and creates no file -- the Null Object
        # duck, not a caller-side `if journal`.
        def spool = Provider::Spool::Null.new
      end

      class << self
        # The one factory the exe calls: a recording Chronicle over a
        # Paths-based fsync journal when journaling is on, the {Null} duck
        # when --no-journal.
        def for(enabled:, tee: nil, paths: Paths.new)
          return Null.new(tee:) unless enabled

          # Computed here, not left to Journal.open's own default, so THIS path
          # is the one #spool later derives the sibling `.wal` from -- the
          # journal and the spool must never be able to name different
          # sessions.
          path = Journal.default_path(paths:)
          new(journal: Journal.open(path, fsync: true), tee:, journal_path: path)
        end

        # Where TurnUsage (the Agent's journal:) and RequestSent (the
        # {Middleware::JournalRequests} phase) land: the given journal, or
        # nowhere. Class-level so {Null} shares the selection with the real
        # thing -- the logic lives once.
        def telemetry_kwargs(journal)
          return {} if journal.nil?

          { journal:,
            model_middleware: Middleware::Stack.new([Middleware::JournalRequests.new(journal:)]) }
        end
      end

      def initialize(journal:, tee: nil, journal_path: nil)
        @journal = journal
        @tee = tee
        @journal_path = journal_path
        @recorder = nil
      end

      # The tools' observer seam ({Event::ChainWriter}'s `observer:` duck),
      # late-bound through {#scribe}: an event before {#start} raises rather
      # than vanishing.
      def observer = ->(event) { scribe.call(event) }

      # The response WAL beside this session's NDJSON: `<session-stem>.wal`,
      # lazily opened so a run that never completes a provider round trip
      # never creates the file (matches {Provider::ResponseWal}'s own lazy
      # writer). Memoized so every provider construction this run makes --
      # the main Agent's and each subagent's -- spools into the SAME file.
      #
      # For T18 (salvage-on-resume): a subagent's round trips land frames here
      # too, but {Middleware::JournalRequests} -- the thing that journals
      # `request_sent` -- is wired only into the main Agent's `model_middleware`
      # (see {.telemetry_kwargs}), so a subagent's frames have no matching
      # `request_sent` digest in the session record. That is BY DESIGN, not a
      # gap this card owes: salvage keys off `request_sent`, so subagent frames
      # simply cannot be salvage targets today, and T18 should not assume every
      # frame in the file is matchable.
      def spool
        @spool ||= Provider::ResponseWal.new(wal_path)
      end

      # Write the OPEN header, pinning exactly what the Agent renders with.
      def start(context:, toolset:, workspace: Workspace.empty)
        @scribe = SessionRecord::Scribe.new(journal: @journal, context:, toolset:, workspace:)
        self
      end

      # Decorate the run's Session so its reads and todo writes ALSO land in
      # the session record ({Session::Journaled}) -- run-state records go to
      # the session journal itself, never the tee, because they are record
      # data like the scribe's turn records, not live-view telemetry. Usable
      # before {#start}: the decorator writes through the journal directly,
      # no scribe involved.
      def wrap_session(session)
        Session::Journaled.new(session:, journal: @journal)
      end

      # Register the run's {Memory::Recorder} so {#telemetry_kwargs} pairs
      # each turn_usage with the memory root in force at that turn
      # ({Memory::JournalMemoryRoot} -- until now wired only on the bench
      # paths, so a live chat's journal carried no memory_root records and a
      # replay would silently rebuild empty memory). Returns the recorder
      # UNCHANGED: JournalMemoryRoot decorates the journal, not the recorder,
      # so Session's `memory:` and the memory tools keep the recorder duck
      # they already speak.
      def wrap_memory(recorder)
        @recorder = recorder
        recorder
      end

      # Per-iteration durability: every committed turn is on disk before the
      # NEXT model call. The scribe duck handed to {Middleware::JournalTurns}
      # is `self`, so this stack can be wired before {#start} -- iterations
      # only run during asks, after the header exists.
      def turn_middleware(timeline)
        Middleware::Stack.new([Middleware::JournalTurns.new(scribe: self, timeline:)])
      end

      # Telemetry follows the tee when --nvim fans events to live views too;
      # otherwise it lands in the session journal itself. With a recorder
      # wrapped, ONLY the Agent's `journal:` leg (the turn_usage stream) is
      # decorated with JournalMemoryRoot -- JournalRequests keeps the raw
      # destination, run_recorder's precedent: request_sent lands unpaired.
      def telemetry_kwargs
        destination = @tee || @journal
        kwargs = self.class.telemetry_kwargs(destination)
        return kwargs if @recorder.nil?

        kwargs.merge(journal: Memory::JournalMemoryRoot.new(journal: destination, recorder: @recorder))
      end

      def catch_up(timeline)
        scribe.catch_up(timeline)
        self
      end

      def interrupted(head:)
        scribe.interrupted(head:)
        self
      end

      # Skips the session_closed record when nothing started: chat's ensure
      # runs even when wiring raised before the header was written, and a
      # closer with no header would be an orphan record (while raising here
      # would mask the original error).
      def close(reason: :exit)
        @scribe&.close(reason:)
        @journal.close
        self
      end

      private

      def scribe
        @scribe or raise NotStarted, "the chronicle has not started: no toolset was pinned, so there " \
                                     "is no scribe to record through -- call #start first"
      end

      # Same stem as the NDJSON, `.wal` in place of whatever extension the
      # journal path carries -- "<session-stem>.wal beside the NDJSON" per
      # the response-WAL plan, not a hardcoded ".ndjson" strip.
      #
      # FLAG: this couples #spool to whatever filename shape Journal.default_path
      # produces (currently `<timestamp>-<pid>.ndjson`) purely by string surgery
      # on the SAME path .for already computed -- there is no shared naming
      # authority between Journal and ResponseWal. Fine while ONE method (.for)
      # is the only place that decides both names; would need a real seam
      # (Journal handing back a stem, not a full path) if a second caller ever
      # needs to derive a WAL path independently.
      def wal_path
        stem = File.basename(@journal_path, ".*")
        File.join(File.dirname(@journal_path), "#{stem}.wal")
      end
    end
  end
end
