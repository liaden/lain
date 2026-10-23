# frozen_string_literal: true

module Lain
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
    # Reviewed 2026-10-23 against published list rates for the Claude 5.5
    # family, Fable 5.1 and Mythos 5.1, plus the Opus 5/4.8/4.7/4.6 family,
    # Sonnet and Haiku 4.5. A row can carry prompt-size tiers and a daily
    # off-peak window, but not a rate that expires on a date or one chosen by a
    # request flag. Two gaps, recorded rather than silently left wrong:
    #
    # * `claude-fable-5` and `claude-mythos-5` have no row and deliberately raise
    #   {UnknownModel} rather than matching a family token -- they are
    #   unpriced pending a row of their own, and a guessed row is worse than a
    #   loud refusal.
    # * Opus 5's fast mode bills a different rate for the SAME model id, under a
    #   request-level flag this table cannot see.
    #
    # Each closes with an exact-model key, not by changing the family match.
    DEFAULTS = {
      "opus" => Price.per_mtok(input: 5, output: 25, cache_creation: 6.25, cache_read: 0.5),
      "sonnet" => Price.per_mtok(input: 3, output: 15, cache_creation: 3.75, cache_read: 0.3),
      "haiku" => Price.per_mtok(input: 1, output: 5, cache_creation: 1.25, cache_read: 0.1),
      "claude-opus-5-5" => Price.per_mtok(input: 4, output: 20, cache_creation: 5, cache_read: 0.2),
      "claude-sonnet-5-5" => Price.per_mtok(input: 2, output: 10, cache_creation: 2.5, cache_read: 0.1),
      "claude-haiku-5-5" => Price.per_mtok(
        input: 0.1, output: 0.5, cache_creation: 0.125, cache_read: 0.01,
        tiers: [Price::Tier.new(
          above_prompt_tokens: 100_000,
          price: Price.per_mtok(input: 0.5, output: 2.5, cache_creation: 0.625, cache_read: 0.05)
        )]
      ),
      "claude-fable-5-1" => Price.per_mtok(input: 10, output: 50, cache_creation: 12.5, cache_read: 0.25),
      "claude-mythos-5-1" => Price.per_mtok(input: 10, output: 50, cache_creation: 12.5, cache_read: 0.25)
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
      @keys = ModelTable.new(@prices.keys)
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

    # The flat rate one request under `model` is billed at, its prompt-size
    # tier and off-peak window already applied.
    #
    # @param model [String, Symbol]
    # @param usage [Lain::Usage]
    # @param at [Time, nil] when the request was sent; nil is the standard rate
    # @return [Price] with no tiers and no off_peak
    def rate(model, usage, at: nil)
      price(model).rate_for(usage, at:)
    end

    # The dollar cost of `usage` under `model`.
    #
    # @param model [String, Symbol]
    # @param usage [Lain::Usage]
    # @param at [Time, nil] when the request was sent; nil is the standard rate
    # @return [BigDecimal]
    def cost(model, usage, at: nil)
      price(model).cost(usage, at:)
    end

    # A constant, not a memoized class ivar, so there is no first-call race. Deep
    # frozenness comes from the constructor, not from this line.
    DEFAULT = new(prices: DEFAULTS)

    private

    def matched(name)
      key = @keys.key_for(name)
      key && @prices.fetch(key)
    end

    def unknown!(name)
      raise UnknownModel, "no price for model #{name.inspect}; configure a fallback to degrade"
    end
  end
end
