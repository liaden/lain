# frozen_string_literal: true

module Lain
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

    class SessionClosed
      # REASONS is reopened onto the class rather than declared inside the
      # `Data.define ... do` block: a constant there is lexically scoped to the
      # enclosing MODULE (Telemetry), not the Data class (the pinned Ruby trap the
      # Request::SYSTEM_PREFIX comment records).

      # `:salvaged` names a closed-file shape none of the other three is honest
      # about: {CLI::Resume::Salvager} closes the file from a LATER process than
      # the one that opened it, after recovering what it could from the response
      # log -- not because the run stopped on purpose or was interrupted
      # mid-turn.
      REASONS = %i[exit interrupted grace_expired salvaged].freeze

      # `respond_to?` rather than a bare `to_sym`, and nil is the case that
      # forces it: a reconstruction from a journal line written before a field
      # existed hands in `record["reason"]&.to_sym`, and that must arrive as this
      # enum's own ArgumentError naming what IS permitted -- not a NoMethodError
      # raised from inside the guard, which names nothing a caller can act on.
      def self.reason!(reason)
        symbol = reason.respond_to?(:to_sym) ? reason.to_sym : reason
        return symbol if REASONS.include?(symbol)

        raise ArgumentError, "reason must be one of #{REASONS.inspect}, got #{reason.inspect}"
      end
    end
  end
end
