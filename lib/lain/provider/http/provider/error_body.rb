# frozen_string_literal: true

require "json"

# New code, not a port. Upstream folds error-body parsing
# (`parse_error`/a JSON-or-string `try_parse_json` fallback) directly into
# `Provider`, which -- together with {Registry} -- pushed the class past
# this project's default `Metrics/ClassLength` (100). Turning a raw response
# body into the message {ErrorMiddleware} wraps in an exception is a real,
# separate responsibility from one instance's `#complete` round trip, so it
# is extracted rather than disabled away. Behavior is unchanged.

module Lain
  class Provider
    module HTTP
      class Provider
        # Best-effort extraction of a human-readable message from a
        # provider's (possibly not-yet-JSON-parsed) error response body.
        module ErrorBody
          module_function

          def parse(response)
            return if response.body.empty?

            body = try_parse_json(response.body)
            case body
            when Hash then parse_hash(body)
            when Array then body.map { |part| parse_hash(part) }.join(". ")
            else body
            end
          end

          def parse_hash(body)
            error = body["error"]
            return error if error.is_a?(String)

            body.dig("error", "message")
          end

          def try_parse_json(maybe_json)
            return maybe_json unless maybe_json.is_a?(String)

            JSON.parse(maybe_json)
          rescue JSON::ParserError
            maybe_json
          end
        end
      end
    end
  end
end
