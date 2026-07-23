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
      # ({Sink::Null}'s idiom). `@tee` starts nil and is set only through
      # {#wrap_tee} -- --nvim's telemetry leg, which exists independently of
      # the session record. The `(**)` signatures accept the real methods'
      # keywords without naming arguments a Null never reads.
      class Null
        # Nil is the honest answer: --no-journal has no file, and /fork reads
        # this to refuse composing a selector no record backs.
        def journal_path = nil
        def observer = Event::ChainWriter::Null.new
        def start(**) = self
        def wrap_session(session) = session
        def wrap_memory(recorder) = recorder
        def turn_middleware(_timeline) = Middleware::Stack.new
        def telemetry_kwargs = Chronicle.telemetry_kwargs(@tee)
        def catch_up(_timeline) = self
        def rewound(**) = self
        def interrupted(**) = self
        def close(**) = self

        # --no-journal + --nvim: there is no session record to share (no
        # journal was ever opened), so nvim gets its OWN real journal --
        # exactly the file it opened before this class carried a #wrap_tee
        # seam at all. Still returns the journal it opened, the same duck the
        # real Chronicle's #wrap_tee answers, so the exe's wiring is one line
        # regardless of which Chronicle it holds.
        def wrap_tee(channel)
          journal = Journal.open
          @tee = JournalTee.new(journal, channel)
          journal
        end

        # --no-journal's answer to {Chronicle#spool}: the same Null spool
        # {Provider::AnthropicRaw} already defaults to, so a provider built
        # with it opens no `.wal` and creates no file -- the Null Object
        # duck, not a caller-side `if journal`.
        def spool = Provider::Spool::Null.new
      end

      # The chronicle-owned spool indirection (T3). Providers are constructed
      # with the spool ONCE, before any promotion can happen, so the object
      # they hold must survive a mid-session rename. Two cases, split by
      # whether the wal file exists when {Chronicle#promote!} relocates:
      #
      # - bytes already on disk: {Paths::Ephemeral} renamed the file and the
      #   inner {Provider::ResponseWal}'s open append fd tracks the inode --
      #   the SAME inner keeps writing, nothing to do.
      # - no wal yet (the lazy never-spooled case): the inner would create
      #   its file at the STALE marked path on the first frame, so it is
      #   swapped for a fresh one at the promoted path -- it never opened
      #   anything, so nothing is lost.
      #
      # Recorded limitation: a frame OPEN across the promotion in the no-wal
      # case still holds the old inner and would land marked; promotion is a
      # user action between round trips, so the window is not wired to occur.
      class RelocatableSpool
        def initialize(path)
          @path = path
          @wal = Provider::ResponseWal.new(path)
        end

        def open_frame(request_digest:) = @wal.open_frame(request_digest:)

        def close = @wal.close

        def relocate(path)
          @wal = Provider::ResponseWal.new(path) unless File.exist?(path)
          @path = path
          self
        end
      end

      class << self
        # The one factory the exe calls: a recording Chronicle over a
        # Paths-based fsync journal when journaling is on, the {Null} duck
        # when --no-journal. Takes no `tee:` -- a caller wanting --nvim's
        # tee wraps it AFTER construction, through {#wrap_tee}, so the tee's
        # journal leg can be the ONE journal this method just opened rather
        # than a second one opened independently (the split-second bug this
        # seam exists to close: two `Journal.open` calls landing on
        # different filenames when they straddle a clock tick).
        #
        # `btw:` (T3) marks the session ephemeral: the SAME default path
        # wearing the `.btw` mark ({Paths.ephemeral_for}), so the wal
        # derivation and the whole record format are untouched -- ephemerality
        # is the filename, reaped by {#close} on a clean exit unless
        # {#promote!} ran first.
        def for(enabled:, btw: false, paths: Paths.new)
          return Null.new unless enabled

          # Computed here, not left to Journal.open's own default, so THIS path
          # is the one #spool later derives the sibling `.wal` from -- the
          # journal and the spool must never be able to name different
          # sessions.
          path = Journal.default_path(paths:)
          path = Paths.ephemeral_for(path) if btw
          new(journal: Journal.open(path, fsync: true), journal_path: path)
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

      # `@tee` starts nil and is set only through {#wrap_tee} -- there is no
      # production caller left that constructs a Chronicle with a tee
      # already in hand, now that --nvim wraps one over the journal THIS
      # opens rather than handing in one built from a second, independent
      # journal.
      def initialize(journal:, journal_path: nil)
        @journal = journal
        @tee = nil
        @journal_path = journal_path
        @recorder = nil
      end

      # The session's on-disk identity, read by /fork (T16) to compose the
      # child's `--fork <session>@<head>` selector. Nil for an injected-io
      # chronicle (no file), exactly as {#promote!} already refuses.
      attr_reader :journal_path

      # The tools' observer seam ({Event::ChainWriter}'s `observer:` duck),
      # late-bound through {#scribe}: an event before {#start} raises rather
      # than vanishing.
      def observer = ->(event) { scribe.call(event) }

      # --nvim shares THIS session's own journal instead of opening a second
      # one: the tee's journal leg becomes `@journal`, so {#telemetry_kwargs}
      # (which prefers `@tee` once this has run) routes request_sent/
      # turn_usage/memory_root into the SAME file the scribe writes turns
      # into -- one Journal instance, one Monitor, no split-second race
      # between two independent `Journal.open` calls. Returns the journal
      # itself: the nvim frontend's OWN `journal:` kwarg (where a hand-edited
      # resend lands) must be this identical journal, not a second one.
      def wrap_tee(channel)
        @tee = JournalTee.new(@journal, channel)
        @journal
      end

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
      #
      # Answers a {RelocatableSpool} (T3): providers hold this ONE object for
      # the whole run, so {#promote!} can retarget a not-yet-created wal
      # without changing the duck they were constructed with.
      def spool
        @spool ||= RelocatableSpool.new(wal_path)
      end

      # T3: promote this session's ephemeral record in place -- the
      # {Paths::Ephemeral} renames (WAL first), then the chronicle's OWN paths
      # retarget, because it is the live holder of both: the journal fd
      # survives the rename untouched (append mode, same inode), and the
      # spool must not lazily create a wal at the stale marked path on its
      # first frame (the {RelocatableSpool} seam).
      #
      # @return [String] the promoted journal path
      def promote!
        raise ArgumentError, "no journal path to promote (an injected-io chronicle has no file)" if @journal_path.nil?

        @journal_path = Paths::Ephemeral.new(@journal_path).promote!
        @spool&.relocate(wal_path)
        @journal_path
      end

      # Write the OPEN header, pinning exactly what the Agent renders with.
      # A resumed chat (T19) passes `resumed_from:` (the chained-header shape)
      # and `written:` (the resumed chain's turn digests) straight through to
      # the scribe -- see {SessionRecord::Scribe#initialize} for why both.
      # `message_journal` is the tee when --nvim wrapped one (the exe's
      # open_chronicle runs {#wrap_tee} before any wiring calls this), so Q/A
      # message records fan to the live views while the file gets them once --
      # see {SessionRecord::Scribe#initialize}.
      def start(context:, toolset:, workspace: Workspace.empty, resumed_from: nil, written: [])
        @scribe = SessionRecord::Scribe.new(journal: @journal, context:, toolset:, workspace:,
                                            resumed_from:, written:, message_journal: @tee)
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

      # T15: announce a rewind to the scribe -- see {SessionRecord::Scribe#rewound}.
      def rewound(to:)
        scribe.rewound(to:)
        self
      end

      def interrupted(head:)
        scribe.interrupted(head:)
        self
      end

      # Skips the session_closed record when nothing started: chat's ensure
      # runs even when wiring raised before the header was written, and a
      # closer with no header would be an orphan record (while raising here
      # would mask the original error). `@spool&.close`, not `spool.close`:
      # the spool is a long-lived append handle that opens its `.wal` lazily
      # on first frame, and a run that never spooled a frame must still
      # create no file at teardown -- reading `@spool` directly (rather than
      # calling {#spool}) is what keeps that lazy open from being forced.
      def close(reason: :exit)
        @scribe&.close(reason:)
        @spool&.close
        @journal.close
        reap_ephemeral if reason == :exit
        self
      end

      private

      # T3: an UNPROMOTED ephemeral reaps on the one clean close (`:exit`) --
      # a promoted session's path no longer wears the mark, so it survives by
      # the same test. Every other reason (`:interrupted`, `:grace_expired`,
      # `:salvaged`) leaves the pair on disk for salvage, as does a hard kill,
      # where no close runs at all. After `@journal.close`, so the fd is gone
      # before the unlink.
      def reap_ephemeral
        return if @journal_path.nil? || !Paths.ephemeral?(@journal_path)

        Paths::Ephemeral.new(@journal_path).reap!
      end

      def scribe
        @scribe or raise NotStarted, "the chronicle has not started: no toolset was pinned, so there " \
                                     "is no scribe to record through -- call #start first"
      end

      # {Paths.wal_for} is the one naming authority; {Resume::Salvager} reads
      # back the same derivation on the same file after a crash.
      def wal_path = Paths.wal_for(@journal_path)
    end
  end
end
