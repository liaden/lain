# frozen_string_literal: true

require "bigdecimal"

module Lain
  class Compare
    # A dollar figure that sums: {Priced} is a measured amount, {Unpriced} absorbs
    # (one unknowable figure makes the total unknowable), and {NONE} is the unit,
    # "nothing was spent here at all". {NONE} is not {Priced} of 0: a run that never
    # compacted has no figure to report, which a measured zero would claim.
    module Cost
      # Each case answers {#refuses?} so a report never asks which one it holds, and
      # {#to_a} so a distribution takes only the amounts that were measured.
      Priced = Data.define(:amount) do
        def refuses? = false
        def to_a = [amount]

        def +(other)
          other.is_a?(Priced) ? Priced.new(amount: amount + other.amount) : other + self
        end
      end

      # Never a zero: reading {#amount} raises the {Ledger}'s refusal again, so a
      # caller that folds the number anyway fails loudly instead of reporting "free".
      Unpriced = Data.define(:reason) do
        # The one wording every report that folds costs refuses in. The Ledger's
        # message already names the fix, so a second phrasing here would be a
        # second authority on how to make a run priceable.
        #
        # @param unpriced [Array<Unpriced>]
        # @return [String]
        def self.describe(unpriced) = "not priced — #{unpriced.map(&:reason).uniq.join("; ")}"

        def initialize(reason:)
          super(reason: -reason.to_s)
        end

        def refuses? = true
        def to_a = []
        # Keeps the left reason: the sum compares by refusal only, and describe reads reasons from the run prices.
        def +(_other) = self

        # @raise [PriceBook::UnknownModel] always
        def amount = raise PriceBook::UnknownModel, reason
      end

      None = Data.define do
        def refuses? = false
        def to_a = []
        def +(other) = other
        def to_s = "none"
      end

      NONE = None.new

      # @param costs [Enumerable<Priced, Unpriced, None>]
      # @return [Priced, Unpriced, None]
      def self.sum(costs) = costs.sum(NONE)
    end
  end
end
