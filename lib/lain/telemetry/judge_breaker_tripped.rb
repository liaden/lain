# frozen_string_literal: true

module Lain
  module Telemetry
    JudgeBreakerTripped = Data.define(:requester, :count, :because)

    # The judge-denial breaker stopped asking the judge about a requester's
    # calls: `count` judge denials, `because` saying which bound they crossed.
    # Every later call of that requester parks for a human.
    class JudgeBreakerTripped
      include Journalable

      # @param requester [String] as {Approval::Parked::Queue.identity_for} names it
      # @param count [Integer]
      # @param because [String] "3 in a row" or "20 this session"
      def initialize(requester:, count:, because:)
        super(requester: -requester.to_s, count: Integer(count), because: -because.to_s)
      end
    end
  end
end
