# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 500. Retriable: {Connection::MiddlewareStack} lists it.
      class ServerError < Error; end
    end
  end
end
