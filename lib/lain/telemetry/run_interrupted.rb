# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Head and status default to nil, the shape the stored corpus holds when a stream died first.
      class RunInterrupted < Declarative::Carrier
        attribute :head, default: nil
        attribute :reason, default: :torn
        attribute :status, default: nil
        attribute :detail, default: nil
        attribute :reset_at, default: nil
        attribute :spawn, default: nil
      end
    end

    # A single run stopped before its response committed. Distinct from
    # {SessionClosed}: the session lives on, but THIS ask produced no complete
    # turn, so `head` names the last committed turn it was generating from --
    # the interruption is in the record, not inferred from a gap.
    #
    # `reason` says WHICH stop it was, because the gap alone cannot: a run the
    # human interrupted, a fleet the shutdown window closed on, and a stream the
    # model stopped feeding all leave the identical hole, and only the first two
    # are anybody's decision.
    #
    # `spawn` names the child whose run paused, as a child's other records do;
    # nil is main's own run, which every record written before the field was.
    RunInterrupted = Data.define(:head, :reason, :status, :detail, :reset_at, :spawn) do
      include Journalable

      def initialize(head:, reason: :torn, status: nil, detail: nil, reset_at: nil, spawn: nil)
        super(**Carriers::RunInterrupted.settle!(head:, reason: self.class.reason!(reason), status:, detail:,
                                                 reset_at:, spawn: spawn&.then { -_1.to_s }))
      end

      # Left off at their nil default, so a record with no status or head is the line it always was.
      def to_journal = omitting_defaults(super, Carriers::RunInterrupted, :head, :status, :detail, :reset_at, :spawn)
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
      # The middle seven are what {Agent::StopReason} reads off the error an
      # ask ended with. `:torn` is the honest residue and the default, because
      # it is the only thing every stopped run is known to have in common: a
      # record built with no classification says the unclassified thing rather
      # than borrowing a narrower one it cannot support.
      #
      # The tail is the stops a reply itself ended on, named by `Response#failure`'s stop_reason.
      REASONS = %i[interrupted grace_expired stopped ceiling over_window transport rejected stalled_stream torn
                   middleware max_tokens context_full refusal truncated malformed unknown quota].freeze

      # The stops a person made: the rest ended the ask without them.
      HUMAN = %i[interrupted grace_expired stopped].freeze

      # A reason read back from a session file is a String and a live one a Symbol, so the test is on the name.
      HUMAN_NAMES = HUMAN.map(&:to_s).freeze

      # @param reason [Object] any value; one that names no stop is not a human's
      def self.human?(reason) = HUMAN_NAMES.include?(reason.to_s)

      # @return [Boolean] whether the human is the one who ended the run
      def human? = self.class.human?(reason)

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
