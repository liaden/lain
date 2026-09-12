# frozen_string_literal: true

require_relative "trail"

# The second half, which depends on Trail#record having kept arrival order.
class Summary
  def initialize(trail)
    @trail = trail
  end

  def to_s = nil
end
