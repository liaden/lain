# frozen_string_literal: true

require "bigdecimal"

require_relative "usage"
require_relative "price_book"

module Lain
  # Aggregates token usage and dollar cost across one or more Timelines, counting
  # each turn EXACTLY ONCE by its content-address.
  #
  # This is the payoff of the Timeline being a content-addressed Merkle DAG, and a
  # real correctness trap. Two branches share a prefix; that prefix is one set of
  # turns stored once, but naively summing usage over every branch would add the
  # shared turns once per branch and over-report both tokens and cost. Aggregating
  # over the set of UNIQUE reachable digests is correct by construction -- the same
  # reason {Lain::Usage} is a commutative monoid: the total must not depend on how
  # many branches happen to walk through a shared turn, nor on walk order.
  #
  # Per-turn usage is read from `turn.meta` (Canonical-normalized, so string keys):
  # `meta["usage"]` is a token Hash and `meta["model"]` names the model that
  # priced it. A turn carrying no usage contributes {Lain::Usage.zero} and no
  # cost, so user turns and un-instrumented turns are simply free.
  class Ledger
    USAGE_KEY = "usage"
    MODEL_KEY = "model"

    # @param price_book [Lain::PriceBook] how a model's usage becomes dollars
    # @param usage_key [String] `meta` key holding the per-turn usage Hash
    # @param model_key [String] `meta` key holding the per-turn model name
    def initialize(price_book: PriceBook.default, usage_key: USAGE_KEY, model_key: MODEL_KEY)
      @price_book = price_book
      @usage_key = usage_key
      @model_key = model_key
    end

    # Total usage over the unique reachable turns of every given Timeline.
    #
    # @param timelines [Array<Lain::Timeline>]
    # @return [Lain::Usage]
    def usage(*timelines)
      unique_turns(timelines).values.reduce(Usage.zero) { |sum, turn| sum + usage_of(turn) }
    end

    # Total dollar cost over the unique reachable turns, each priced by its own
    # model. Unlike {#usage} this cannot be a single monoid fold: two turns of
    # different models add different dollars for the same tokens, so cost is summed
    # per turn against that turn's model.
    #
    # @param timelines [Array<Lain::Timeline>]
    # @return [BigDecimal]
    def cost(*timelines)
      unique_turns(timelines).values.reduce(BigDecimal(0)) { |sum, turn| sum + cost_of(turn) }
    end

    # One record per unique reachable turn -- digest, model, usage, cost -- for a
    # per-turn Journal line or a breakdown. Ordered oldest-first for stable
    # reading; order does not affect the totals.
    #
    # @param timelines [Array<Lain::Timeline>]
    # @return [Array<Hash>]
    def per_turn(*timelines)
      unique_turns(timelines).values.map do |turn|
        {
          "digest" => turn.digest,
          "model" => turn.meta[@model_key],
          "usage" => usage_of(turn).to_h,
          "cost" => cost_of(turn)
        }
      end
    end

    private

    # digest => Turn across all timelines, deduplicated by content-address. A Hash
    # keyed on the digest is the whole point: the shared prefix collapses to one
    # entry no matter how many branches reach it.
    def unique_turns(timelines)
      timelines.flatten.each_with_object({}) do |timeline, acc|
        timeline.ancestors { |turn| acc[turn.digest] ||= turn }
      end
    end

    def usage_of(turn)
      raw = turn.meta[@usage_key]
      return Usage.zero unless raw.is_a?(Hash)

      Usage.new(**raw.transform_keys(&:to_sym))
    end

    def cost_of(turn)
      usage = usage_of(turn)
      return BigDecimal(0) if usage.zero?

      @price_book.cost(turn.meta[@model_key], usage)
    end
  end
end
