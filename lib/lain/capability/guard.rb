# frozen_string_literal: true

require_relative "../error"

module Lain
  module Capability
    # The gate `Compare` stands behind: two runs may only be compared when they
    # degraded the SAME capabilities. If one arm silently lost `:thinking` and the
    # other did not, then half the tactic under study never ran on that arm, and
    # any distribution drawn across the two is measuring the missing tactic, not
    # the variable. So the guard REFUSES rather than reports -- a lie you can read
    # is worse than an error you cannot ignore.
    #
    # Standalone by design: `Compare` (a later unit) calls
    # {Guard.guard!} with the two runs' {DegradedSet}s; nothing here depends on
    # `Compare` existing.
    module Guard
      # Raised when two runs' degraded sets differ, making them incomparable.
      class Mismatch < Lain::Error; end

      # @param set_a [DegradedSet]
      # @param set_b [DegradedSet]
      # @return [true] when the sets are equal
      # @raise [Mismatch] when they differ
      def self.guard!(set_a, set_b)
        return true if set_a == set_b

        raise Mismatch,
              "cannot compare runs with differing degraded sets: " \
              "#{set_a.to_a.inspect} vs #{set_b.to_a.inspect}"
      end
    end
  end
end
