# frozen_string_literal: true

require "bigdecimal"

require_relative "ledger/index"

module Lain
  # Aggregates token usage and dollar cost across one or more Timelines: the
  # spend attributable to the turns REACHABLE from the given heads, joined from
  # the Journal's `turn_usage` records by content-address.
  #
  # Two different aggregations meet here, and conflating them is the trap:
  #
  # 1. CONTENT is deduplicated. Two branches share a prefix; that prefix is one
  #    set of turns stored once, and naively summing over every branch would
  #    count it once per branch. So the walk covers UNIQUE reachable digests --
  #    the payoff of the Timeline being a content-addressed Merkle DAG, and the
  #    same reason {Lain::Usage} is a commutative monoid: the total must not
  #    depend on how many branches walk through a shared turn, nor on order.
  # 2. PAYMENTS are not. A reachable digest may carry several {Index::Entry}s
  #    (rewind, then identical regeneration), and every one was genuinely paid
  #    for, so a turn's usage and cost sum over ALL its recorded payments.
  #
  # Spend on rewound branches whose turns are no longer reachable from any
  # given head is invisible to this walk BY DESIGN -- reachability is the
  # question the Ledger answers. Whole-run usage regardless of reachability is
  # the sum over every journal record, which is what {Agent::Accounting#usage}
  # already accumulates.
  #
  # Not nested under Journal: Ledger CONSUMES journals (it walks a Timeline and
  # joins against journal-sourced payments), it does not produce or own them.
  # Journal must not know its readers, so nesting a reader under the thing it
  # reads would point the dependency the wrong way. This class lives with
  # pricing/accounting instead.
  class Ledger
    # Convenience: fold journal entries (parsed Hashes or raw NDJSON lines)
    # straight into a priced Ledger.
    #
    # @param entries [Enumerable<Hash, String>]
    # @param price_book [Lain::PriceBook]
    # @return [Ledger]
    def self.from_journal(entries, price_book: PriceBook.default)
      new(index: Index.from_journal(entries), price_book:)
    end

    # @param index [Ledger::Index] digest => payments, REQUIRED -- a Ledger with
    #   no usage source would silently price every turn at zero, and on a bench
    #   whose headline metric is cost, silence is the failure mode
    # @param price_book [Lain::PriceBook] how a model's usage becomes dollars
    def initialize(index:, price_book: PriceBook.default)
      @index = index
      @price_book = price_book
    end

    # Total usage over the unique reachable turns of every given Timeline.
    #
    # @param timelines [Array<Lain::Timeline>]
    # @return [Lain::Usage]
    def usage(*timelines)
      unique_turns(timelines).values.reduce(Usage.zero) { |sum, turn| sum + usage_of(turn) }
    end

    # Total dollar cost over the unique reachable turns, each payment priced by
    # its own model. Unlike {#usage} this cannot be a single monoid fold: two
    # payments under different models add different dollars for the same tokens.
    #
    # @param timelines [Array<Lain::Timeline>]
    # @return [BigDecimal]
    def cost(*timelines)
      unique_turns(timelines).values.reduce(BigDecimal(0)) { |sum, turn| sum + cost_of(turn) }
    end

    private

    # The turn's usage: the monoid sum over every payment recorded against its
    # digest. A digest the Journal never priced contributes {Usage.zero}, so
    # user turns and un-instrumented turns are simply free.
    #
    # @param turn [Lain::Event]
    # @return [Lain::Usage]
    def usage_of(turn)
      @index.entries_for(turn.digest).reduce(Usage.zero) { |sum, entry| sum + entry.usage }
    end

    # The turn's dollar cost: each payment priced against ITS OWN recorded
    # model. A payment with no model raises {PriceBook::UnknownModel} -- a
    # silently-free payment would be a lie -- unless the PriceBook carries a
    # fallback, which still prices it.
    #
    # @param turn [Lain::Event]
    # @return [BigDecimal]
    def cost_of(turn)
      @index.entries_for(turn.digest).reduce(BigDecimal(0)) do |sum, entry|
        sum + turn_cost(turn, entry)
      end
    end

    # PriceBook must stay the one authority on pricing (its fallback has to
    # keep working for nil), so the nil-model case is rescued and re-raised
    # rather than pre-checked: PriceBook's own "no price for model \"\"" would
    # send the first mock-journal user grepping the wrong codebase.
    def turn_cost(turn, entry)
      @price_book.cost(entry.model, entry.usage)
    rescue PriceBook::UnknownModel
      raise unless entry.model.nil?

      raise PriceBook::UnknownModel,
            "turn #{turn.digest}: payment recorded no model (a bare mock or un-instrumented " \
            "provider reports none); pass a PriceBook with a fallback to price these"
    end

    # digest => turn event across all timelines, deduplicated by content-address. A Hash
    # keyed on the digest is the whole point: the shared prefix collapses to one
    # entry no matter how many branches reach it.
    def unique_turns(timelines)
      timelines.flatten.each_with_object({}) do |timeline, acc|
        timeline.ancestors { |turn| acc[turn.digest] ||= turn }
      end
    end
  end
end
