# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # Not a status of its own. {ErrorMiddleware} raises it for a 400 or a 429
      # whose message matches one of its context-length patterns, because both
      # codes carry that complaint depending on the provider.
      class ContextLengthExceededError < Error; end
    end
  end
end
