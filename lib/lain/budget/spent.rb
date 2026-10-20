# frozen_string_literal: true

module Lain
  module Budget
    # What a run has used. Iterations are absent on purpose: the count is per
    # ask and resets, which no monoid fold can express.
    Spent = Data.define(:usage, :dollars) do
      def self.zero = new(usage: Usage.zero, dollars: Friction::CacheWaste::Dollars.zero)

      def +(other)
        self.class.new(usage: usage + other.usage, dollars: dollars + other.dollars)
      end
    end
  end
end
