# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The count stays untyped here: the record coerces it to Integer.
      class JudgeBreakerTripped < Declarative::Carrier
        attribute :requester, :lain_interned
        attribute :count
        attribute :because, :lain_interned
      end
    end

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
        settled = Carriers::JudgeBreakerTripped.settle!(requester:, count:, because:)

        super(**settled, count: Integer(settled[:count]))
      end
    end
  end
end
