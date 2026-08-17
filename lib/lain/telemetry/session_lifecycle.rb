# frozen_string_literal: true

module Lain
  module Telemetry
    # The session-record FORMAT's lifecycle events (T13): how a session ended,
    # how one run inside it ended, and the non-turn Events promoted into it.

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

    class SessionClosed
      # REASONS is reopened onto the class rather than declared inside the
      # `Data.define ... do` block: a constant there is lexically scoped to the
      # enclosing MODULE (Telemetry), not the Data class (the pinned Ruby trap the
      # Request::SYSTEM_PREFIX comment records).

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
      # this is where its envelope + body become the flat record. A :turn
      # arriving on that funnel belongs to a SPAWNED chain and wears
      # {ChildTurn} instead -- see there for why the two cannot share a record.
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

    # A SPAWNED chain's turn, promoted to the session record. Its own type, and
    # the reason is mechanical: a child's chain shares no render edge with the
    # parent's, so {Bench::Session::ChainFold} -- which re-commits every `turn`
    # record onto ONE accumulating chain -- would re-derive a different digest
    # for it and call the file {Bench::Session::Corrupt}. It cannot wear the
    # `message` shape either: a :turn's `render_parent` IS part of its content
    # address, and {Message} does not carry one.
    #
    # It has to be recorded at all because things OUTSIDE the child's chain
    # cite it -- a child's `ask_human` question names the head it asked from,
    # and {Tools::Subagent::Lineage#message} names the child's final turn -- so
    # a session that spawned anything was previously unforkable: replaying
    # those messages raised {Store::MissingObject} over a turn no record
    # carried.
    #
    # It is not cheap, and the price is the child's whole transcript: measured
    # over `Provider::Mock` runs, these records are 47% of a journal with one
    # trivial spawn in it and 88% of one with eight four-deep spawns (136KB,
    # 180 records, 18.6ms to reload). That is the dominant term in a
    # spawn-heavy run's file, and it is the deliberate cost of the session
    # being forkable at all -- a subagent's work was previously the one part
    # of a run the experiment record could not reproduce.
    ChildTurn = Data.define(:digest, :kind, :from, :to, :render_parent, :payload, :causal_parents, :correlation) do
      include Journalable

      def self.from_event(event)
        new(digest: event.digest, kind: event.kind, from: event.from, to: event.to,
            render_parent: event.render_parent, payload: event.body,
            causal_parents: event.causal_parents, correlation: event.correlation)
      end

      def initialize(digest:, kind:, from:, to:, render_parent:, payload:, causal_parents:, correlation:)
        super(
          digest: digest.dup.freeze,
          kind: kind.to_sym,
          from: Canonical.normalize(from),
          to: Canonical.normalize(to),
          render_parent: Canonical.normalize(render_parent),
          payload: Canonical.normalize(payload),
          causal_parents: Canonical.normalize(causal_parents),
          correlation: Canonical.normalize(correlation)
        )
      end
    end
  end
end
