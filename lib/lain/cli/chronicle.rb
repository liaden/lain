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
        def turn_middleware(_timeline) = Middleware::Stack.new
        def telemetry_kwargs = Chronicle.telemetry_kwargs(@tee)
        def catch_up(_timeline) = self
        def interrupted(**) = self
        def close(**) = self
      end

      class << self
        # The one factory the exe calls: a recording Chronicle over a
        # Paths-based fsync journal when journaling is on, the {Null} duck
        # when --no-journal.
        def for(enabled:, tee: nil, paths: Paths.new)
          return Null.new(tee:) unless enabled

          new(journal: Journal.open(fsync: true, paths:), tee:)
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

      def initialize(journal:, tee: nil)
        @journal = journal
        @tee = tee
      end

      # The tools' observer seam ({Event::ChainWriter}'s `observer:` duck),
      # late-bound through {#scribe}: an event before {#start} raises rather
      # than vanishing.
      def observer = ->(event) { scribe.call(event) }

      # Write the OPEN header, pinning exactly what the Agent renders with.
      def start(context:, toolset:, workspace: Workspace.empty)
        @scribe = SessionRecord::Scribe.new(journal: @journal, context:, toolset:, workspace:)
        self
      end

      # Per-iteration durability: every committed turn is on disk before the
      # NEXT model call. The scribe duck handed to {Middleware::JournalTurns}
      # is `self`, so this stack can be wired before {#start} -- iterations
      # only run during asks, after the header exists.
      def turn_middleware(timeline)
        Middleware::Stack.new([Middleware::JournalTurns.new(scribe: self, timeline:)])
      end

      # Telemetry follows the tee when --nvim fans events to live views too;
      # otherwise it lands in the session journal itself.
      def telemetry_kwargs = self.class.telemetry_kwargs(@tee || @journal)

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
    end
  end
end
