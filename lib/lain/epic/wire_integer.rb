# frozen_string_literal: true

module Lain
  module Epic
    # A positive integer as it arrives off a wire, read strictly. Two fields need
    # it and both are KEYS -- a review's `generation` and an annotation's `line`
    # -- and every coercion Ruby offers is wrong for a key: `"7abc".to_i` and
    # `7.9.to_i` are both 7, `nil.to_i` is 0, and `Integer()` truncates a Float
    # the same way, so a shallow reading names a review, or a line, that nobody
    # sent. One reader because there is one rule; the two fields drifting apart
    # is how the shallow version came back.
    module WireInteger
      def self.read(value, field:)
        return value if value.is_a?(Integer) && value.positive?
        return value.to_i if value.is_a?(String) && value.match?(/\A[1-9][0-9]*\z/)

        raise ArgumentError, "#{field} must be a positive canonical integer, got #{value.inspect}"
      end
    end
  end
end
