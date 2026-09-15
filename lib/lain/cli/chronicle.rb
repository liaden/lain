# frozen_string_literal: true

module Lain
  module CLI
    # The durable session record's lifecycle for one chat run: the exe wires
    # collaborators; this object owns WHEN the journal opens, what the scribe's
    # header pins, which journal telemetry lands in, and how the record closes.
    #
    # Two-phase by necessity: the tools need {#observer} at construction, but the
    # scribe's header pins the FINISHED toolset -- so construction opens the
    # journal and {#start} writes the header. Anything needing the scribe earlier
    # raises {NotStarted} loudly, because a silently swallowed early event would
    # be record loss.
    class Chronicle
      class NotStarted < Error; end

      # The same duck with no record behind it (--no-journal), so the exe carries
      # no nil-checks. The `(**)` signatures accept the real methods' keywords
      # without naming arguments a Null never reads.
      class Null
        # Nil is the honest answer: --no-journal has no file, and /fork reads
        # this to refuse composing a selector no record backs.
        def journal_path = nil
        def observer = Event::ChainWriter::Null.new
        def start(**) = self
        def wrap_session(session) = session
        def wrap_memory(recorder) = recorder
        def turn_middleware(_timeline) = Middleware::Stack.new
        def instrumentation = Chronicle.instrumentation(@tee)

        # No record was ever opened, and {Channel::Null} is not a journal (it
        # answers `#<<`, not `#record`). The null device is the same duck,
        # discarding.
        def record_journal = @tee || durable_journal

        # Memoised because it OPENS the null device, and every journal-role
        # collaborator of a run asks for it. Never the tee: under --nvim that
        # is nvim's own journal, and these records were never nvim's to fold.
        def durable_journal = @durable_journal ||= Journal.new(io: File.open(File::NULL, "ab"))

        def catch_up(_timeline) = self
        def rewound(**) = self
        def interrupted(**) = self
        def close(**) = self

        # --no-journal + --nvim: there is no session record to share, so nvim
        # gets its OWN real journal. Returns it, the same duck the real
        # {Chronicle#wrap_tee} answers, so the exe's wiring is one line either
        # way.
        def wrap_tee(channel)
          journal = Journal.open
          @tee = JournalTee.new(journal, channel)
          journal
        end

        # The same Null spool {Provider::Anthropic} already defaults to, so a
        # provider built with it opens no `.wal` and creates no file.
        def spool = Provider::Spool::Null.new
      end

      # Providers are constructed with the spool ONCE, before any promotion can
      # happen, so the object they hold must survive a mid-session rename. Two
      # cases, split by whether the wal file exists when {Chronicle#promote!}
      # relocates:
      #
      # - bytes already on disk: the rename is invisible to the inner
      #   {Provider::ResponseWal}, whose append fd tracks the inode.
      # - no wal yet: the inner would create its file at the STALE marked path on
      #   the first frame, so it is swapped for a fresh one at the promoted path.
      #
      # Known limitation: a frame OPEN across the promotion in the no-wal case
      # still holds the old inner and lands marked. Promotion is a user action
      # between round trips, so the window is not wired to occur.
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
        # A recording Chronicle over a Paths-based fsync journal, or the {Null}
        # duck under --no-journal. Takes no `tee:` -- --nvim wraps one AFTER
        # construction, through {#wrap_tee}, so the tee's journal leg is the ONE
        # journal this method opened. Two independent `Journal.open` calls
        # straddling a clock tick land on different filenames.
        #
        # `btw:` marks the session ephemeral: the SAME default path wearing the
        # `.btw` mark, so the wal derivation and the record format are untouched.
        # Ephemerality is the filename, reaped by {#close} on a clean exit unless
        # {#promote!} ran first.
        def for(enabled:, btw: false, paths: Paths.new)
          return Null.new unless enabled

          # Computed here, not left to Journal.open's own default, so THIS path
          # is the one #spool derives the sibling `.wal` from -- the journal and
          # the spool must never be able to name different sessions.
          path = Journal.default_path(paths:)
          path = Paths.ephemeral_for(path) if btw
          new(journal: Journal.open(path, fsync: true), journal_path: path)
        end

        # Where TurnUsage and RequestSent land: the given journal, or nowhere.
        # Class-level so {Null} shares the selection with the real thing.
        #
        # A nil journal answers the all-Null {Agent::Instrumentation} rather than
        # an empty Hash the Agent fills from its own defaults: "reports nowhere"
        # is a value, not an absent key.
        def instrumentation(journal)
          return Agent::Instrumentation.new if journal.nil?

          requests = Middleware::Stack.new([Middleware::JournalRequests.new(journal:)])
          Agent::Instrumentation.new(journal:, model_middleware: requests)
        end
      end

      # `@tee` starts nil and is set only through {#wrap_tee}: --nvim wraps one
      # over the journal THIS opens, rather than handing in one built over a
      # second, independent journal.
      def initialize(journal:, journal_path: nil)
        @journal = journal
        @tee = nil
        @journal_path = journal_path
        @recorder = nil
      end

      # Read by /fork to compose the child's `--fork <session>@<head>` selector.
      # Nil for an injected-io chronicle, exactly as {#promote!} refuses.
      attr_reader :journal_path

      # Late-bound through {#scribe}: an event before {#start} raises rather
      # than vanishing.
      def observer = ->(event) { scribe.call(event) }

      # --nvim shares THIS session's own journal instead of opening a second
      # one, so telemetry lands in the SAME file the scribe writes turns into:
      # one Journal instance, one Monitor, no split-second race between two
      # independent `Journal.open` calls. Returns the journal itself, because the
      # nvim frontend's OWN `journal:` kwarg -- where a hand-edited resend lands
      # -- must be this identical instance.
      def wrap_tee(channel)
        @tee = JournalTee.new(@journal, channel)
        @journal
      end

      # The response WAL beside this session's NDJSON, lazily opened so a run
      # that never completes a round trip never creates the file. Memoized so
      # every provider this run builds -- the main Agent's and each subagent's --
      # spools into the SAME file.
      #
      # A subagent's frames have no matching `request_sent` digest in the record,
      # because {Middleware::JournalRequests} is wired only into the main Agent's
      # `model_middleware`. That is deliberate: salvage keys off `request_sent`,
      # so subagent frames cannot be salvage targets and salvage must not assume
      # every frame in the file is matchable.
      #
      # A {RelocatableSpool}, so {#promote!} can retarget a not-yet-created wal
      # without changing the duck providers were constructed with.
      def spool
        @spool ||= RelocatableSpool.new(wal_path)
      end

      # {Paths::Ephemeral} renames (WAL first), then this object's OWN paths
      # retarget, because it is the live holder of both: the journal fd survives
      # the rename untouched (append mode, same inode), and the spool must not
      # lazily create a wal at the stale marked path on its first frame.
      #
      # @return [String] the promoted journal path
      def promote!
        raise ArgumentError, "no journal path to promote (an injected-io chronicle has no file)" if @journal_path.nil?

        @journal_path = Paths::Ephemeral.new(@journal_path).promote!
        @spool&.relocate(wal_path)
        @journal_path
      end

      # Write the OPEN header, pinning exactly what the Agent renders with. A
      # resumed chat passes `resumed_from:` and `written:` through to the scribe.
      # `message_journal` is the tee when --nvim wrapped one, so Q/A message
      # records fan to the live views while the file gets them once.
      # @see SessionRecord::Scribe#initialize
      def start(context:, toolset:, workspace: Workspace.empty, resumed_from: nil, written: [])
        @scribe = SessionRecord::Scribe.new(journal: @journal, context:, toolset:, workspace:,
                                            resumed_from:, written:, message_journal: @tee)
        self
      end

      # Run-state records go to the session journal itself, never the tee: they
      # are record data like the scribe's turn records, not live-view telemetry.
      # Usable before {#start}, because the Session writes through the journal
      # directly with no scribe involved.
      #
      # The SAME object comes back, which is what a resumed chat needs: its
      # Session was folded out of the old record by {SessionRecord::Replay}
      # with no journal attached, and rebuilding it here would lose the
      # read-set, pin-set and todo list that replay just restored.
      def wrap_session(session)
        session.journals_into(@journal)
      end

      # Registers the recorder so each turn_usage is paired with the memory root
      # in force at that turn. Wired only on the bench paths before, which left a
      # live chat's journal with no memory_root records and a replay silently
      # rebuilding empty memory. Returns the recorder UNCHANGED, because
      # {Memory::JournalMemoryRoot} decorates the journal, not the recorder.
      def wrap_memory(recorder)
        @recorder = recorder
        recorder
      end

      # Per-iteration durability: every committed turn is on disk before the
      # NEXT model call. The scribe duck handed on is `self`, so this stack can
      # be wired before {#start} -- iterations run only during asks.
      def turn_middleware(timeline)
        Middleware::Stack.new([Middleware::JournalTurns.new(scribe: self, timeline:)])
      end

      # Telemetry follows the tee when --nvim fans events to live views, and the
      # session journal otherwise. With a recorder wrapped, ONLY the turn_usage
      # leg is decorated: request_sent lands unpaired, run_recorder's precedent.
      def instrumentation
        destination = @tee || @journal
        resolved = self.class.instrumentation(destination)
        return resolved if @recorder.nil?

        resolved.with(journal: Memory::JournalMemoryRoot.new(journal: destination, recorder: @recorder))
      end

      # The journal a run's own switches record into. They speak `#record`,
      # which {Channel::Null} does not, so "there is no record" and "the record
      # discards" are different answers and this reader is what tells them apart.
      # The same destination {#instrumentation} carries, so a flip and a
      # turn_usage cannot land in two different files.
      def record_journal = instrumentation.journal

      # The journal a record nothing live folds goes to: a shell arm, a lease, a
      # handback, a reap, a spawn seam's refusals. The session journal under
      # every setting and never the tee, because the tee also feeds
      # {StatusFeed} and {FleetWindows}, which count what reaches them. A record
      # a live view DOES fold goes to {#record_journal} instead.
      def durable_journal = @journal

      def catch_up(timeline)
        scribe.catch_up(timeline)
        self
      end

      # Announce a rewind to the scribe -- see {SessionRecord::Scribe#rewound}.
      def rewound(to:)
        scribe.rewound(to:)
        self
      end

      # The two call paths classify differently: {Conductor#close} holds the
      # signal's own reason, {Repl::Ask#refuse} derives one from the error that
      # tore the ask. Neither argument defaults -- an ArgumentError on a caller's
      # first run is cheaper than a plausible lie in the file.
      #
      # @param head [String, nil] the last committed turn the torn run ran from
      # @param reason [Symbol] one of {Telemetry::RunInterrupted::REASONS}
      # @return [self]
      def interrupted(head:, reason:)
        scribe.interrupted(head:, reason:)
        self
      end

      # Skips the session_closed record when nothing started: chat's ensure runs
      # even when wiring raised before the header was written, and a closer with
      # no header would be an orphan record, while raising here would mask the
      # original error. `@spool&.close` and not `spool.close`, because calling
      # {#spool} would force the lazy open a never-spooled run must not create.
      def close(reason: :exit)
        @scribe&.close(reason:)
        @spool&.close
        @journal.close
        reap_ephemeral if reason == :exit
        self
      end

      private

      # An UNPROMOTED ephemeral reaps on the one clean close: a promoted
      # session's path no longer wears the mark, so it survives the same test,
      # and every other reason leaves the pair on disk for salvage. Runs after
      # `@journal.close`, so the fd is gone before the unlink.
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
