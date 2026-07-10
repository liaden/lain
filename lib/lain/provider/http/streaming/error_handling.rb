# frozen_string_literal: true

require_relative "../error_middleware"

# Split from streaming.rb -- see that file's header. Streaming error handling
# is a real, separate responsibility from the SSE engine: a successful stream
# never reaches any of these methods. They recognize an error chunk/payload,
# reconstruct a response-shaped object, and hand it to {ErrorMiddleware} to
# raise the same typed error the non-streaming path would.
#
# Composed into {Provider} the same way {Streaming} is (`include`), not
# delegated to, because these methods must run with the provider as `self`:
# `parse_streaming_error` is provider-overridable (Anthropic's version, in
# providers/anthropic/streaming.rb, replaces the generic one below), and
# {ErrorMiddleware}.parse_error is called with `provider: self`. That is the
# ActiveSupport::Concern-style composition of orthogonal behavior CLAUDE.md
# endorses -- two distinct modules mixed into one class -- not one oversized
# module reopened across files. `stream_debug` / `faraday_1?` resolve back
# through `self` onto {Streaming}, which is mixed into the same provider.

module Lain
  class Provider
    module HTTP
      module Streaming
        # Recognizes and raises streaming errors; see the file header.
        module ErrorHandling
          module_function

          def error_chunk?(chunk)
            chunk.start_with?("event: error")
          end

          def json_error_payload?(chunk)
            chunk.lstrip.start_with?("{") && chunk.include?('"error"')
          end

          def handle_json_error_chunk(chunk, env)
            parse_error_from_json(chunk, env, "Failed to parse JSON error chunk")
          end

          def handle_error_chunk(chunk, env)
            error_data = chunk.split("\n")[1].delete_prefix("data: ")
            parse_error_from_json(error_data, env, "Failed to parse error chunk")
          end

          def handle_failed_response(chunk, buffer, env)
            buffer << chunk
            error_data = JSON.parse(buffer)
            handle_parsed_error(error_data, env)
          rescue JSON::ParserError
            stream_debug { "Accumulating error chunk: #{chunk}" }
          end

          def handle_error_event(data, env)
            parse_error_from_json(data, env, "Failed to parse error event")
          end

          # The generic fallback; Anthropic overrides this (529 vs 500 on an
          # overloaded_error). A provider with no streaming.rb uses this one.
          def parse_streaming_error(data)
            error_data = JSON.parse(data)
            [500, error_data["message"] || "Unknown streaming error"]
          rescue JSON::ParserError => e
            stream_debug { "Failed to parse streaming error: #{e.message}" }
            [500, "Failed to parse error: #{data}"]
          end

          def handle_parsed_error(parsed_data, env)
            status, _message = parse_streaming_error(parsed_data.to_json)
            error_response = build_stream_error_response(parsed_data, env, status)
            ErrorMiddleware.parse_error(provider: self, response: error_response)
          end

          def parse_error_from_json(data, env, error_message)
            parsed_data = JSON.parse(data)
            handle_parsed_error(parsed_data, env)
          rescue JSON::ParserError => e
            stream_debug { "#{error_message}: #{e.message}" }
          end

          def build_stream_error_response(parsed_data, env, status)
            error_status = status || env&.status || 500

            if faraday_1?
              Struct.new(:body, :status).new(parsed_data, error_status)
            else
              env.merge(body: parsed_data, status: error_status)
            end
          end
        end
      end
    end
  end
end
