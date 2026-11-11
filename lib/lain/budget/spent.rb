# frozen_string_literal: true

module Lain
  module Budget
    # What a run has used. Iterations are absent on purpose: the count is per
    # ask and resets, which no monoid fold can express.
    Spent = Data.define(:usage, :dollars) do
      def self.zero = new(usage: Usage.zero, dollars: Friction::CacheWaste::Dollars.zero)

      # A pricing gap must never fail a call already paid for; it marks the
      # dollars incomplete instead.
      #
      # @param response [#model, #usage] one round trip's answer
      # @param prices [PriceBook] what it is priced under
      # @param clock [#call] the time it arrived, which a rate may depend on
      # @return [Spent]
      def self.of(response, prices:, clock:) = paid(response.model, response.usage, prices:, clock:)

      # {.of} for a payment read back from a record, which carries no response.
      #
      # @param model [String]
      # @param usage [Usage]
      # @param prices [PriceBook]
      # @param clock [#call]
      # @return [Spent]
      def self.paid(model, usage, prices:, clock:)
        new(usage:, dollars: Friction::CacheWaste::Dollars.of(prices.cost(model, usage, at: clock.call)))
      rescue PriceBook::UnknownModel
        new(usage:, dollars: Friction::CacheWaste::Dollars.unknown)
      end

      def +(other)
        self.class.new(usage: usage + other.usage, dollars: dollars + other.dollars)
      end
    end
  end
end
