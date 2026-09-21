# frozen_string_literal: true

require "bigdecimal"

module Lain
  # The dollar price of one model's four token classes. Cost accounting is OURS,
  # deliberately not a vendored pricing table: the numbers live in code, where
  # the bench owns them.
  #
  # All arithmetic is `BigDecimal`, never Float. Token counts reach the hundreds
  # of thousands against tiny per-token prices, so Float would accumulate
  # rounding error across a session, and a cost metric that drifts is worse than
  # none. Prices are quoted per million tokens and divided down once, exactly.
  Price = Data.define(:input, :output, :cache_creation, :cache_read) do
    # Build a Price from per-million-token dollar figures.
    #
    # @return [Price] with per-token `BigDecimal` rates
    def self.per_mtok(input:, output:, cache_creation:, cache_read:)
      new(**{ input:, output:, cache_creation:, cache_read: }
        .transform_values { |quoted| dollars(quoted) / 1_000_000 })
    end

    # Coerce a number to BigDecimal via its String form, so `0.1` is exactly 0.1
    # rather than the binary Float that `BigDecimal(0.1)` would refuse without a
    # precision argument.
    def self.dollars(value)
      value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    end

    # The dollar cost of a {Lain::Usage}, each token class at its own rate.
    #
    # @param usage [Lain::Usage]
    # @return [BigDecimal]
    def cost(usage)
      (input * usage.input_tokens) +
        (output * usage.output_tokens) +
        (cache_creation * usage.cache_creation_input_tokens) +
        (cache_read * usage.cache_read_input_tokens)
    end
  end
end
