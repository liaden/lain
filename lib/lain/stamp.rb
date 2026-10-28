# frozen_string_literal: true

require "time"

module Lain
  # Parses a journal or feed timestamp that may be torn or absent. A bad stamp
  # must not destroy a report over a file a user pointed us at, so it reads as
  # unstamped (nil) instead of raising.
  module Stamp
    module_function

    # @param value [Object] an ISO8601 String, or anything else
    # @return [Time, nil] a frozen Time, or nil when value is not a parseable String
    def iso8601(value)
      Time.iso8601(value).freeze if value.is_a?(String)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
