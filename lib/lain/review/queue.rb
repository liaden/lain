# frozen_string_literal: true

module Lain
  module Review
    # What a reviewer should look at next: rows from every source, best reason
    # first, minus any head the human already opened. Whether a head was
    # opened is a fold of {Log}, never state held here.
    class Queue
      include Enumerable

      # Best first. A row's rank is one of these, so a source cannot invent an
      # ordering the queue does not know how to place.
      RANKS = %i[plan_run re_review direct team path branch dirty commit].freeze

      # @param sources [Array<#call>] each answers its rows
      # @param log [Log]
      def initialize(sources:, log:)
        @sources = sources
        @log = log
      end

      # @yieldparam row [Row]
      def each(&)
        return enum_for(:each) unless block_given?

        rows = @sources.flat_map(&:call).reject { |row| @log.seen?(row) }
        ranked = rows.each_with_index.sort_by { |row, at| [place(row), at] }
        ranked.map(&:first).each(&)
      end

      private

      def place(row)
        RANKS.index(row.rank) || raise(KeyError, "unknown rank #{row.rank.inspect}")
      end
    end
  end
end
