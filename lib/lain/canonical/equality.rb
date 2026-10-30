# frozen_string_literal: true

require "json"

module Lain
  module Canonical
    # An equality a digest memo can trust: true only when the dumps are equal;
    # false can still mean equal bytes, which costs a miss. Ruby's `==` holds 1
    # equal to 1.0 and 0.0 equal to -0.0, which dump differently, so a memo
    # that reuses a digest on `==` serves one value's digest for another.
    module Equality
      module_function

      # `eql?` is the deep walk, in C, that tells an Integer from a Float; it
      # holds 0.0 and -0.0 alike and ignores a Hash's order, and the dumps,
      # compared only once `eql?` agrees, see both. It also tells a String from
      # a Symbol, which dump alike: a miss, never a stale hit.
      #
      # @param one [Object] a canonical value
      # @param other [Object] another
      # @return [Boolean] true only when the 2 dump to the same bytes; false can still mean equal bytes
      def same?(one, other) = one.equal?(other) || (one.eql?(other) && JSON.generate(one) == JSON.generate(other))
    end
  end
end
