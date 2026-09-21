# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 502, 503 and 504 -- a range rather than a code, because all three say
      # the same thing about a gateway in front of the model. Retriable.
      class ServiceUnavailableError < Error; end
    end
  end
end
