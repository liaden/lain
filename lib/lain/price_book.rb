# frozen_string_literal: true

require "bigdecimal"

require_relative "error"

module Lain
  # The dollar price of one model's four token classes. Cost accounting is OURS,
  # deliberately not a vendored pricing table (the plan rejects dragging in
  # `models.json`): the numbers live here, in code, where the bench owns them.
  #
  # All arithmetic is `BigDecimal`, never Float. Token counts reach the hundreds
  # of thousands and per-token prices are tiny fractions; Float would accumulate
  # rounding error across a session, and a cost metric that drifts is worse than
  # none. Prices are quoted per million tokens (the industry convention) and
  # divided down once, exactly.
  Price = Data.define(:input, :output, :cache_creation, :cache_read) do
    # Build a Price from per-million-token dollar figures.
    #
    # @return [Price] with per-token `BigDecimal` rates
    def self.per_mtok(input:, output:, cache_creation:, cache_read:)
      new(**{ input: input, output: output, cache_creation: cache_creation, cache_read: cache_read }
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

  # A per-model price map. Given a model name and a {Lain::Usage}, it answers the
  # dollar cost. Matching is exact first, then by the longest known family token
  # the model name contains -- so `"claude-3-5-sonnet-20241022"` resolves to the
  # `sonnet` family without the map having to enumerate every dated snapshot.
  #
  # An unknown model raises rather than guessing a price of zero: on a bench whose
  # headline metric is cost, a silently-free model is a lie. A deployment that
  # wants graceful degradation passes an explicit `fallback` Price.
  class PriceBook
    class UnknownModel < Error; end

    # Representative Anthropic list prices, per million tokens, USD. These are the
    # bench's DEFAULT map and are meant to be overridden, not treated as an
    # oracle: prices change, and the point of keeping them here is that changing
    # them is a one-line edit under version control, not a vendored 1.4 MB table.
    # Cache-write is Anthropic's 1.25x input; cache-read is its 0.1x input.
    DEFAULTS = {
      "opus" => Price.per_mtok(input: 15, output: 75, cache_creation: 18.75, cache_read: 1.5),
      "sonnet" => Price.per_mtok(input: 3, output: 15, cache_creation: 3.75, cache_read: 0.3),
      "haiku" => Price.per_mtok(input: 0.8, output: 4, cache_creation: 1.0, cache_read: 0.08)
    }.freeze

    # @return [PriceBook] the bench's default map
    def self.default
      @default ||= new(prices: DEFAULTS)
    end

    # @param prices [Hash{String=>Price}] family/model token => Price
    # @param fallback [Price, nil] used for an unmatched model; nil means raise
    def initialize(prices: DEFAULTS, fallback: nil)
      @prices = prices.transform_keys(&:to_s)
      @fallback = fallback
    end

    # The Price for a model name.
    #
    # @param model [String, Symbol]
    # @return [Price]
    # @raise [UnknownModel] if unmatched and no fallback was configured
    def price(model)
      name = model.to_s
      @prices.fetch(name) { matched(name) || @fallback || unknown!(name) }
    end

    # The dollar cost of `usage` under `model`.
    #
    # @return [BigDecimal]
    def cost(model, usage)
      price(model).cost(usage)
    end

    private

    # Longest family token the name contains, so a more specific key wins over a
    # more general one were both present.
    def matched(name)
      key = @prices.keys.select { |token| name.include?(token) }.max_by(&:length)
      key && @prices.fetch(key)
    end

    def unknown!(name)
      raise UnknownModel, "no price for model #{name.inspect}; configure a fallback to degrade"
    end
  end
end
