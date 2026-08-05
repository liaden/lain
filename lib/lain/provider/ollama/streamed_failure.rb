# frozen_string_literal: true

require "json"

module Lain
  class Provider
    class Ollama < Provider
      # The body of a FAILED streaming response, kept where the error that
      # finally surfaces can speak from it.
      #
      # Faraday hands a streamed body to the request's `on_data` and then sets
      # `env.body` to empty (faraday-net_http's `perform_request`), so by the
      # time {Provider::HTTP::ErrorMiddleware} runs on the way out there is
      # nothing left to quote: it falls through {ErrorMiddleware::STATUS_ERRORS}
      # and `STATUS_MESSAGES` to a literal, and a human typing a model name
      # wrong was told "An unknown error occurred" instead of "model
      # 'no-such-model-xyz' not found". This accumulates the bytes as they go
      # past and re-raises through that SAME middleware with the body ollama
      # actually sent -- so the class, the status and the message are the
      # non-streaming path's exactly, rather than a second, parallel mapping
      # that can drift from it.
      #
      # The reset on every complete object is the part that is not obvious.
      # faraday-retry replays a retried attempt through the same `on_data`
      # handler, so an accumulator that only appends holds `{...}{...}` from the
      # second attempt on -- valid JSON in neither half. That is what destroyed
      # the message on exactly the statuses that get retried.
      class StreamedFailure
        # What {Provider::HTTP::ErrorMiddleware} reads off a response: a body to
        # quote and a status to map. The real response object is long gone, and
        # a Data carries the two fields without pretending to be more.
        ErrorResponse = Data.define(:body, :status)

        # @param provider [Provider::HTTP::Provider] the transport, which
        #   ErrorMiddleware asks to turn a body into a message
        def initialize(provider)
          @provider = provider
          @pending = +""
          @body = nil
        end

        # @param chunk [String] one raw chunk of a non-2xx response body, at
        #   whatever TCP boundary it arrived on
        def feed(chunk)
          @pending << chunk
          JSON.parse(@pending)
          @body = @pending.dup
          @pending.clear
        rescue JSON::ParserError
          nil # an object split across chunks; keep accumulating
        end

        # @param error [Provider::HTTP::Error] what the middleware raised with
        #   the consumed body
        # @raise [Provider::HTTP::Error] `error` itself, or the better error the
        #   streamed body affords. Never returns: `parse_error` raises for every
        #   non-2xx status, and {#supersedes?} is false unless a non-2xx status
        #   is known.
        def reraise(error)
          raise error unless supersedes?(error.response)

          Provider::HTTP::ErrorMiddleware.parse_error(
            provider: @provider,
            response: ErrorResponse.new(body: @body, status: error.response.status)
          )
        end

        private

        # Only when the streamed body says something the raised error could not:
        # a response that DID carry a message keeps it, since that message came
        # from the same body by the same parser and there is nothing to add. The
        # status is the response's real one -- never the severity guess
        # {Streaming::ErrorHandling#parse_streaming_error} would make, which is
        # what relabeled a genuine 400 as a retryable 500 on Anthropic (RES1).
        def supersedes?(response)
          return false if @body.nil?
          return false unless response.respond_to?(:status) && response.respond_to?(:body)
          return false if (200..399).cover?(response.status)

          response.body.nil? || Provider::HTTP::Provider::ErrorBody.parse(response).nil?
        end
      end
    end
  end
end
