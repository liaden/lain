# frozen_string_literal: true

require "faraday"
require_relative "error"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/error_middleware.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::. Faraday middleware registered
# under :lain_provider_http_errors instead of :llm_errors, so the global
# Faraday::Middleware registry never collides with an actual ruby_llm install.
# `.parse_error`'s status dispatch was a ten-branch `case` carrying an inline
# `rubocop:disable Metrics/PerceivedComplexity` upstream; CLAUDE.md forbids
# disabling Metrics cops here, so it is a status -> class/message lookup table
# plus one collaborator (`context_length_exceeded?`) instead. Behavior,
# including the 400/429 context-length sniff, is unchanged.

module Lain
  class Provider
    module HTTP
      # Faraday middleware that maps provider-specific API errors to our own.
      class ErrorMiddleware < Faraday::Middleware
        def initialize(app, options = {})
          super(app)
          @provider = options[:provider]
        end

        def call(env)
          @app.call(env).on_complete do |response|
            self.class.parse_error(provider: @provider, response: response)
          end
        end

        class << self
          CONTEXT_LENGTH_PATTERNS = [
            /context length/i,
            /context window/i,
            /maximum context/i,
            /request too large/i,
            /too many tokens/i,
            /token count exceeds/i,
            /input[_\s-]?token/i,
            /input or output tokens? must be reduced/i,
            /reduce the length of messages/i,
            /prompt is too long/i
          ].freeze

          # Only 400 and 429 are ever reinterpreted as a context-length problem --
          # Anthropic and OpenAI-alikes both surface it as one of these two codes.
          CONTEXT_SENSITIVE_STATUSES = [400, 429].freeze

          STATUS_ERRORS = {
            400 => BadRequestError,
            401 => UnauthorizedError,
            402 => PaymentRequiredError,
            403 => ForbiddenError,
            429 => RateLimitError,
            500 => ServerError,
            529 => OverloadedError
          }.freeze

          STATUS_MESSAGES = {
            400 => "Invalid request - please check your input",
            401 => "Invalid API key - check your credentials",
            402 => "Payment required - please top up your account",
            403 => "Forbidden - you do not have permission to access this resource",
            429 => "Rate limit exceeded - please wait a moment",
            500 => "API server error - please try again",
            529 => "Service overloaded - please try again later"
          }.freeze

          def parse_error(provider:, response:)
            message = provider&.parse_error(response)
            status = response.status
            return message if success?(status)

            raise error_for(status, response, message)
          end

          private

          def success?(status)
            (200..399).cover?(status)
          end

          def error_for(status, response, message)
            return context_length_error(response, message) if context_length_exceeded?(status, message)
            return unavailable_error(response, message) if (502..504).cover?(status)

            klass = STATUS_ERRORS.fetch(status, Error)
            klass.new(response, message || STATUS_MESSAGES[status] || "An unknown error occurred")
          end

          def context_length_error(response, message)
            ContextLengthExceededError.new(response, message || "Context length exceeded")
          end

          def unavailable_error(response, message)
            ServiceUnavailableError.new(response, message || "API server unavailable - please try again later")
          end

          def context_length_exceeded?(status, message)
            return false unless CONTEXT_SENSITIVE_STATUSES.include?(status)
            return false if message.to_s.empty?

            CONTEXT_LENGTH_PATTERNS.any? { |pattern| message.match?(pattern) }
          end
        end
      end
    end
  end
end

Faraday::Middleware.register_middleware(lain_provider_http_errors: Lain::Provider::HTTP::ErrorMiddleware)
