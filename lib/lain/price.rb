# frozen_string_literal: true

require "bigdecimal"

module Lain
  Price = Data.define(:input, :output, :cache_creation, :cache_read, :tiers, :off_peak) do
    # Build a Price from per-million-token dollar figures.
    #
    # @param input [Numeric] dollars per million uncached input tokens
    # @param output [Numeric] dollars per million output tokens
    # @param cache_creation [Numeric] dollars per million cache-write tokens
    # @param cache_read [Numeric] dollars per million cache-read tokens
    # @param tiers [Array<Price::Tier>] dearer rows by prompt size, in any order
    # @param off_peak [Price::OffPeak, nil] the row billed outside the peak window
    # @return [Price] with per-token `BigDecimal` rates
    def self.per_mtok(input:, output:, cache_creation:, cache_read:, tiers: [], off_peak: nil)
      new(**{ input:, output:, cache_creation:, cache_read: }
        .transform_values { |quoted| dollars(quoted) / 1_000_000 }, tiers:, off_peak:)
    end

    # Coerce a number to BigDecimal via its String form, so `0.1` is exactly 0.1
    # rather than the binary Float that `BigDecimal(0.1)` would refuse without a
    # precision argument.
    def self.dollars(value)
      value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    end

    def initialize(input:, output:, cache_creation:, cache_read:, tiers: [], off_peak: nil)
      tiers = Array(tiers).sort_by(&:above_prompt_tokens).freeze
      refuse_nesting(tiers, off_peak)
      super
    end

    # The flat rate one request is billed at. An off-peak row is a whole Price
    # of its own, so in its window its tiers apply and the base row's do not.
    #
    # @param usage [Lain::Usage] its prompt is input + cache_creation + cache_read tokens
    # @param at [Time, nil] nil is the standard (peak) rate
    # @return [Price] with no tiers and no off_peak
    def rate_for(usage, at: nil)
      return self if flat?
      return off_peak.price.rate_for(usage) if at && off_peak&.cover?(at)

      reached = tiers.reverse.find { |tier| usage.total_input_tokens > tier.above_prompt_tokens }
      reached ? reached.price.rate_for(usage) : with(tiers: [], off_peak: nil)
    end

    # The dollar cost of a {Lain::Usage}, each token class at the rate the
    # whole request is billed at.
    #
    # @param usage [Lain::Usage]
    # @param at [Time, nil] when the request was sent; nil is the standard rate
    # @return [BigDecimal]
    def cost(usage, at: nil)
      rate_for(usage, at:).flat_cost(usage)
    end

    protected

    def flat? = tiers.empty? && off_peak.nil?

    def flat_cost(usage)
      (input * usage.input_tokens) +
        (output * usage.output_tokens) +
        (cache_creation * usage.cache_creation_input_tokens) +
        (cache_read * usage.cache_read_input_tokens)
    end

    private

    # The evaluator reads a tier's price and an off-peak price as one row, so
    # anything nested inside them would be dropped without a word.
    def refuse_nesting(tiers, off_peak)
      raise ArgumentError, "a tier's price cannot carry tiers or an off-peak row" unless tiers.all? { _1.price.flat? }
      raise ArgumentError, "an off-peak price cannot carry an off-peak row of its own" if off_peak&.price&.off_peak
    end
  end

  # The dollar price of one model's four token classes. Cost accounting is OURS,
  # deliberately not a vendored pricing table: the numbers live in code, where
  # the bench owns them.
  #
  # All arithmetic is `BigDecimal`, never Float. Token counts reach the hundreds
  # of thousands against tiny per-token prices, so Float would accumulate
  # rounding error across a session, and a cost metric that drifts is worse than
  # none. Prices are quoted per million tokens and divided down once, exactly.
  #
  # Reopened because a constant written in the `Data.define` block would land
  # on {Lain}, not on Price.
  class Price
    # A dearer row that bills the WHOLE request once its prompt passes the
    # boundary, not only the tokens past it, as the published tiers do.
    Tier = Data.define(:above_prompt_tokens, :price)

    OffPeak = Data.define(:price) do
      # @param time [Time] in any zone; the window is read in UTC
      # @return [Boolean]
      def cover?(time)
        utc = time.getutc
        utc.saturday? || utc.sunday? || !(12...18).cover?(utc.hour)
      end
    end
  end
end
