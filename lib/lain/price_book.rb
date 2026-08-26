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

  # A per-model price map. Matching is exact first, then by the longest known
  # family token the model name contains, so `"claude-3-5-sonnet-20241022"`
  # resolves to `sonnet` without enumerating every dated snapshot.
  #
  # An unknown model raises rather than guessing zero: on a bench whose headline
  # metric is cost, a silently-free model is a lie. A deployment that wants
  # graceful degradation passes an explicit `fallback` Price.
  #
  # Ollama Cloud is billed by subscription quota, not per token, so DEFAULT
  # carries no ollama row and no fallback -- #price raises {UnknownModel} for one
  # like any other unpriced model. A row or a process-wide fallback here would
  # silently price every OTHER unknown model too, so the withholding lives one
  # layer up: {Friction::CacheWaste#price_for} rescues UnknownModel per model and
  # {Friction::Report::CacheWasteSection#figure_phrase} renders the gap as an
  # explicit "no price recorded" rather than a fabricated dollar figure.
  class PriceBook
    class UnknownModel < Error; end

    # Representative Anthropic list prices, per million tokens, USD. Meant to be
    # overridden, not treated as an oracle: prices change, and keeping them here
    # makes that a one-line edit under version control rather than a vendored
    # 1.4 MB table. Cache-write is Anthropic's 1.25x input, cache-read its 0.1x.
    #
    # Reviewed 2026-08-18 against published list rates for the Opus 5/4.8/4.7/4.6
    # family, Sonnet and Haiku 4.5. Three gaps a single-rate-per-model row cannot
    # express, recorded rather than silently left wrong:
    #
    # * Sonnet carries an introductory $2/$10 per MTok through 2026-08-31 while
    #   this table holds the $3/$15 list rate that takes over after; the
    #   freshness lint is what catches this drifting behind a later change.
    # * `claude-fable-5` and `claude-mythos-5` have no row and deliberately raise
    #   {UnknownModel} rather than matching a family token -- no rate was
    #   verified, and a guessed row is worse than a loud refusal.
    # * Opus 5's fast mode bills a different rate for the SAME model id, under a
    #   request-level flag this table cannot see.
    #
    # All three close with an exact-model key, not by changing the family match.
    DEFAULTS = {
      "opus" => Price.per_mtok(input: 5, output: 25, cache_creation: 6.25, cache_read: 0.5),
      "sonnet" => Price.per_mtok(input: 3, output: 15, cache_creation: 3.75, cache_read: 0.3),
      "haiku" => Price.per_mtok(input: 1, output: 5, cache_creation: 1.25, cache_read: 0.1)
    }.freeze

    # @return [PriceBook] the bench's default map
    def self.default = DEFAULT

    # @param prices [Hash{String=>Price}] family/model token => Price
    # @param fallback [Price, nil] used for an unmatched model; nil means raise
    def initialize(prices: DEFAULTS, fallback: nil)
      # Deep-frozen: `transform_keys(&:to_s)` builds a fresh MUTABLE Hash (and
      # Symbol#to_s fresh mutable Strings) even over the frozen DEFAULTS, and
      # the shared {DEFAULT} must not be corruptible through it. Price values
      # are Data instances, frozen already.
      @prices = prices.to_h { |key, price| [-key.to_s, price] }.freeze
      @fallback = fallback
      freeze
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

    # A constant, not a memoized class ivar, so there is no first-call race. Deep
    # frozenness comes from the constructor, not from this line.
    DEFAULT = new(prices: DEFAULTS)

    private

    # Longest family token the name contains, so a more specific key wins.
    def matched(name)
      key = @prices.keys.select { |token| name.include?(token) }.max_by(&:length)
      key && @prices.fetch(key)
    end

    def unknown!(name)
      raise UnknownModel, "no price for model #{name.inspect}; configure a fallback to degrade"
    end
  end
end
