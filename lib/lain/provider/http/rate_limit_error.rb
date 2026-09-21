# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 429, unless the body reads as a context-length complaint -- see
      # {BadRequestError}. Retriable: {Connection::MiddlewareStack} lists it.
      class RateLimitError < Error; end
    end
  end
end
