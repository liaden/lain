# frozen_string_literal: true

module Lain
  module Compaction
    # Whether a measured rewrite saves enough to be worth its cache break. Pure: the caller
    # decides which rewrites it is asked about, and a forced one is never asked.
    #
    # Without a horizon or a cache-write price there is no break to price, so the floor alone
    # decides, the same refusal to guess a figure {PriceBook} makes for an unlisted model.
    class Worth
      FLOOR = 0.10
      COMPACT = :compact
      BELOW_FLOOR = :below_floor
      CACHE_BREAK_UNPAID = :cache_break_unpaid

      # The read saving accrues per request, so a plan's open todos are scaled by the requests
      # each completed todo has taken; with either count still 0 the rate is unknown, and so is this.
      #
      # @param open [Integer] todos not yet completed
      # @param completed [Integer] todos completed so far
      # @param requests [Integer] model requests sent so far
      # @return [Rational, nil] requests left, or nil when unknown
      def self.horizon(open:, completed:, requests:)
        Rational(open * requests, completed) unless [open, completed, requests].any?(&:zero?)
      end

      # @param floor [Numeric] the least share of a rewrite's own size it must drop
      def initialize(floor: FLOOR)
        @floor = floor
        freeze
      end

      # @param rewrite [Scheduler::Rewrite] the measured rewrite
      # @param ttl [Numeric, nil] the cache's TTL in seconds; nil or 0 for no cache to break
      # @param prices [Price, nil] the live model's price; nil when the model is unlisted
      # @param steps_left [Numeric, nil] requests a live plan has left, from {.horizon}; nil when unknown
      # @return [Symbol] {COMPACT}, {BELOW_FLOOR} or {CACHE_BREAK_UNPAID}
      def call(rewrite:, ttl:, prices:, steps_left:)
        return BELOW_FLOOR if rewrite.dropped.count < rewrite.before * @floor
        return COMPACT unless priced_break?(ttl, prices, steps_left)

        pays_back?(rewrite, prices, steps_left) ? COMPACT : CACHE_BREAK_UNPAID
      end

      private

      def priced_break?(ttl, prices, steps_left)
        ttl.to_i.positive? && !steps_left.nil? && prices&.cache_creation&.positive?
      end

      def pays_back?(rewrite, prices, steps_left)
        rewrite.dropped.to_tokens * prices.cache_read * steps_left >
          rewrite.remaining.to_tokens * prices.cache_creation
      end
    end
  end
end
