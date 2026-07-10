# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/error.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::. Dropped UnsupportedAttachmentError
# (leak site 10 -- image/audio APIs are out of scope; see VENDOR.md).

module Lain
  class Provider
    module HTTP
      # Wraps API errors from the wire into a consistent, provider-neutral shape.
      class Error < StandardError
        attr_reader :response

        def initialize(response = nil, message = nil)
          if response.is_a?(String)
            message = response
            response = nil
          end

          @response = response
          super(message || response&.body)
        end
      end

      # Non-HTTP errors.
      class ConfigurationError < StandardError; end
      class InvalidRoleError < StandardError; end

      # HTTP status -> error class, applied by {ErrorMiddleware}.
      class BadRequestError < Error; end
      class ForbiddenError < Error; end
      class ContextLengthExceededError < Error; end
      class OverloadedError < Error; end
      class PaymentRequiredError < Error; end
      class RateLimitError < Error; end
      class ServerError < Error; end
      class ServiceUnavailableError < Error; end
      class UnauthorizedError < Error; end
    end
  end
end
