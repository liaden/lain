# frozen_string_literal: true

module Lain
  # The session-record FORMAT's lifecycle events (T13): how a session ended,
  # how one run inside it ended, and the non-turn Events promoted into it.
  module Telemetry
    # A session's final anchor, written by {SessionRecord::Scribe} on a graceful
    # close. `head` is the Timeline head digest at close (nil for a session that
    # committed nothing); `reason` names WHY the session ended -- an enum, closed
    # and loud like {ToolOutput}'s stream, so a typo fails at construction rather
    # than journaling a reason no reader expects. Its presence is what tells a
    # loader an open session (a header with `head: nil` and no closer -- a
    # SIGKILL'd process) apart from one that ended on purpose.
    SessionClosed = Data.define(:head, :reason) do
      include Journalable

      def initialize(head:, reason:)
        super(head: head&.dup&.freeze, reason: self.class.reason!(reason))
      end
    end

    # REASONS is reopened onto the class rather than declared inside the
    # `Data.define ... do` block: a constant there is lexically scoped to the
    # enclosing MODULE (Telemetry), not the Data class (the pinned Ruby trap the
    # Request::SYSTEM_PREFIX comment records).
    class SessionClosed
      # `:salvaged` (T18) is additive: no reader branches on a
      # {SessionClosed} reason's VALUE, only on its presence (that is what
      # tells {Bench::Session::Anchor} a session closed at all) and, here, on
      # membership in this list -- verified before adding it. It names a
      # closed-file shape none of `exit`/`interrupted`/`grace_expired` is
      # honest about: {CLI::Resume::Salvager} closes the file from a LATER
      # process than the one that opened it, after recovering what it could
      # from the response log, not because the run that opened it stopped on
      # purpose or was interrupted mid-turn.
      REASONS = %i[exit interrupted grace_expired salvaged].freeze

      def self.reason!(reason)
        symbol = reason.to_sym
        return symbol if REASONS.include?(symbol)

        raise ArgumentError, "reason must be one of #{REASONS.inspect}, got #{reason.inspect}"
      end
    end

    # A single run stopped before its response committed -- a Ctrl-C (or an
    # expiring grace window) that beat the model's reply back. Distinct from
    # {SessionClosed}: the session lives on, but THIS ask produced no complete
    # turn, so `head` names the last committed turn the interrupted run was
    # generating from (nil if none yet). A reader pairs it with the absence of a
    # following turn record the way {Middleware::JournalRequests} reads a
    # request_sent with no turn_usage -- the interruption is in the record, not
    # inferred from a gap.
    RunInterrupted = Data.define(:head) do
      include Journalable

      def initialize(head:)
        super(head: head&.dup&.freeze)
      end
    end

    # A :message or :spawn Event promoted to the session record, its OWN additive
    # type so the turn-chain loader's `of_type` narrowing never sees it (a
    # :message can never survive {Timeline#commit}'s digest re-derivation, so it
    # must not wear the `turn` shape). Field-pinned to what a later re-put into a
    # Store needs -- `payload` is the addressed body, `causal_parents` the
    # backward edges a provenance walk descends -- carried as data here; T14 owns
    # reconstructing the Store from it.
    Message = Data.define(:digest, :kind, :from, :to, :payload, :causal_parents, :correlation) do
      include Journalable

      # The one funnel {Event::ChainWriter} observes hands the scribe an Event;
      # this is where its envelope + body become the flat record.
      def self.from_event(event)
        new(digest: event.digest, kind: event.kind, from: event.from, to: event.to,
            payload: event.body, causal_parents: event.causal_parents, correlation: event.correlation)
      end

      def initialize(digest:, kind:, from:, to:, payload:, causal_parents:, correlation:)
        super(
          digest: digest.dup.freeze,
          kind: kind.to_sym,
          from: Canonical.normalize(from),
          to: Canonical.normalize(to),
          payload: Canonical.normalize(payload),
          causal_parents: Canonical.normalize(causal_parents),
          correlation: Canonical.normalize(correlation)
        )
      end
    end
  end
end
