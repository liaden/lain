# frozen_string_literal: true

module Lain
  module Telemetry
    # `released` is a subset of `regions`, so more released than found is a
    # malformed record: shape, not a second security check.
    module ReleasedWithinRegions
      extend ActiveSupport::Concern

      included { validate :released_within_regions }

      private

      # Skipped when either count already failed numericality: a Hash has no
      # `#to_i` a raw comparison could fall back on, and that error already
      # names the real problem.
      def released_within_regions
        return if errors[:regions].any? || errors[:released].any?
        return if released.to_i <= regions.to_i

        errors.add(:released, "must be <= regions (#{regions}), got #{released}")
      end
    end
  end
end
