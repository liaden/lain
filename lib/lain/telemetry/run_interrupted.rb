# frozen_string_literal: true

module Lain
  module Telemetry
    # A single run stopped before its response committed. Distinct from
    # {SessionClosed}: the session lives on, but THIS ask produced no complete
    # turn, so `head` names the last committed turn it was generating from --
    # the interruption is in the record, not inferred from a gap.
    #
    # `reason` says WHICH stop it was, because the gap alone cannot: a run the
    # human interrupted, a fleet the shutdown window closed on, and a stream the
    # model stopped feeding all leave the identical hole, and only the first two
    # are anybody's decision.
    RunInterrupted = Data.define(:head, :reason) do
      include Journalable

      def initialize(head:, reason: :torn)
        super(head: head&.dup&.freeze, reason: self.class.reason!(reason))
      end
    end

    class RunInterrupted
      # Reopened, not declared inside the `Data.define ... do` block above, for
      # the reason {SessionClosed}'s own REASONS records: a constant there is
      # lexically scoped to the enclosing MODULE, not the Data class.

      # DELIBERATELY NOT {SessionClosed::REASONS}. That enum answers "how did
      # the SESSION end", and two of its members cannot describe an interrupted
      # run at all -- `:exit` is the clean quit this record contradicts, and
      # `:salvaged` is a later process's verdict on a file -- while it has
      # nowhere to put a stall. The overlap is intended.
      #
      # The middle five are what {Agent::StopReason} reads off the error an
      # ask ended with. `:torn` is the honest residue and the default, because
      # it is the only thing every stopped run is known to have in common: a
      # record built with no classification says the unclassified thing rather
      # than borrowing a narrower one it cannot support.
      REASONS = %i[interrupted grace_expired stopped ceiling over_window transport stalled_stream torn].freeze

      # Mirrors {SessionClosed.reason!}, nil-tolerance included: a guard that
      # refuses differently from its sibling is one a reader has to check
      # twice.
      def self.reason!(reason)
        symbol = reason.respond_to?(:to_sym) ? reason.to_sym : reason
        return symbol if REASONS.include?(symbol)

        raise ArgumentError, "reason must be one of #{REASONS.inspect}, got #{reason.inspect}"
      end
    end
  end
end
