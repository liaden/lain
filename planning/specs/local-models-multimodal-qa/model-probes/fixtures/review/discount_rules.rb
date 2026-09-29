# frozen_string_literal: true

module Shop
  # Applies at most one discount per order: the best one the customer qualifies for.
  #
  # Rules, from the pricing doc:
  #   - Orders of $100.00 or more get 10% off.
  #   - Gold and platinum loyalty members get 15% off regardless of total.
  #   - Everyone gets 5% off in December.
  #   - Guest checkouts have no loyalty tier (customer.loyalty_tier is nil).
  class DiscountRules
    BULK_THRESHOLD_CENTS = 100_00
    BULK_RATE = 10
    SEASONAL_RATE = 5
    TIER_RATES = { "GOLD" => 15, "PLATINUM" => 15 }.freeze

    Result = Data.define(:rate, :reason) do
      def self.none = new(rate: 0, reason: :none)

      def apply(cents) = cents - (cents * rate / 100r).round
    end

    def initialize(clock: Time)
      @clock = clock
    end

    def best_for(order, customer)
      candidates(order, customer).max_by(&:rate) || Result.none
    end

    private

    def candidates(order, customer)
      [bulk(order), loyalty(customer), seasonal].compact
    end

    def bulk(order)
      Result.new(rate: BULK_RATE, reason: :bulk) if order.total_cents > BULK_THRESHOLD_CENTS #BUG2
    end

    def loyalty(customer)
      rate = TIER_RATES[customer.loyalty_tier.upcase] #BUG3
      Result.new(rate:, reason: :loyalty) if rate
    end

    def seasonal
      Result.new(rate: SEASONAL_RATE, reason: :seasonal) if @clock.now.month == 12
    end
  end
end
