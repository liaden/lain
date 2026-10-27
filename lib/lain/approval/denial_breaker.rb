# frozen_string_literal: true

module Lain
  module Approval
    # What `auto` does with a judge's refusals, per requester. The breaker
    # counts them and, past {IN_A_ROW} in a row or {PER_SESSION} in all, stops
    # asking the judge about that requester: a model refusing a run of calls is
    # better settled by a person than by the same model again. Only the
    # judge's denials reach it, so a human's never counts.
    #
    # A session here is one board: a resume or a restart builds a new breaker,
    # so its counts start fresh. Once tripped, the judge is not asked, so a
    # requester's later calls add no judge deny to the tripwire's evidence.
    #
    # The counts are kept under a lock of this object's and the record written
    # once it is released, as {Tripwire::Ledger} does, so no caller waits on
    # the journal while holding it.
    class DenialBreaker
      IN_A_ROW = 3
      PER_SESSION = 20
      IN_A_ROW_SAID = "#{IN_A_ROW} in a row".freeze
      PER_SESSION_SAID = "#{PER_SESSION} this session".freeze

      Count = Data.define(:run, :total)

      # The arms that never trip: `off` applies a judge's deny, `escalate_only` hands it down.
      class Unbroken
        def initialize(maps_deny:)
          @maps_deny = maps_deny
          freeze
        end

        def tripped?(_requester) = false

        def denied(_requester) = nil

        def approved(_requester) = nil

        def maps_deny? = @maps_deny
      end

      Off = Unbroken.new(maps_deny: false)
      EscalateOnly = Unbroken.new(maps_deny: true)

      # @param arm [Symbol, String] one of {CLI::Arms::JUDGE_DENIALS}
      # @param journal [#<<] where the breaker's trip is written
      # @return [DenialBreaker, Unbroken]
      # @raise [ArgumentError] on any other arm
      def self.for(arm, journal:)
        case arm.to_sym
        when :off then Off
        when :escalate_only then EscalateOnly
        when :breaker then new(journal:)
        else raise ArgumentError, "judge denials are off, escalate_only or breaker, not #{arm}"
        end
      end

      # @param journal [#<<]
      def initialize(journal:)
        @journal = journal
        @lock = Mutex.new
        @counts = Hash.new(Count.new(run: 0, total: 0))
        @tripped = {}
      end

      # @param requester [String]
      # @return [Boolean] whether the judge is no longer asked about this requester's calls
      def tripped?(requester) = @lock.synchronize { @tripped.key?(requester) }

      # A judge's deny of one of this requester's calls.
      #
      # @param requester [String]
      # @return [void]
      def denied(requester)
        trip = @lock.synchronize { counted(requester) }
        @journal << trip if trip
        nil
      end

      # A judge's approve, which ends a run of denials and leaves the session's total.
      #
      # @param requester [String]
      # @return [void]
      def approved(requester)
        @lock.synchronize { @counts[requester] = @counts[requester].with(run: 0) }
        nil
      end

      def maps_deny? = false

      private

      def counted(requester)
        count = @counts[requester]
        count = @counts[requester] = Count.new(run: count.run + 1, total: count.total + 1)
        because = crossed(count)
        because && !@tripped.key?(requester) && trip(requester, because, count)
      end

      def crossed(count)
        if count.run >= IN_A_ROW then IN_A_ROW_SAID
        elsif count.total >= PER_SESSION then PER_SESSION_SAID
        end
      end

      def trip(requester, because, count)
        @tripped[requester] = because
        Telemetry::JudgeBreakerTripped.new(requester:, count: because == IN_A_ROW_SAID ? count.run : count.total,
                                           because:)
      end
    end
  end
end
