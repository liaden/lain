# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # HTTP 400, unless the body reads as a context-length complaint --
      # {ErrorMiddleware} sniffs 400 and 429 for that and answers
      # {ContextLengthExceededError} instead.
      class BadRequestError < Error; end
    end
  end
end
