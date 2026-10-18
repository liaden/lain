# frozen_string_literal: true

require "json"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/providers/anthropic/streaming.rb.
# Only the hooks the live transport calls are kept: `stream_url` and
# `parse_streaming_error`. Chunk building went with the vendored request and
# response model.

module Lain
  class Provider
    module HTTP
      module Providers
        class Anthropic
          # The Anthropic-specific streaming hooks the base SSE engine calls.
          module Streaming
            private

            def stream_url
              completion_url
            end

            def parse_streaming_error(data)
              error_data = JSON.parse(data)
              return unless error_data["type"] == "error"

              case error_data.dig("error", "type")
              when "overloaded_error"
                [529, error_data["error"]["message"]]
              else
                [500, error_data["error"]["message"]]
              end
            end
          end
        end
      end
    end
  end
end

# Mixed in HERE rather than from anthropic.rb: this file reopens that class, so
# an include written over there would wait on a require already in flight
# whenever the loader reached this file first. Outside the class body, and so
# fully qualified, to leave that body a pure namespace -- the one shape
# Style/Documentation exempts without a second docstring on a reopened class,
# which is a docstring YARD silently discards.
Lain::Provider::HTTP::Providers::Anthropic.include(Lain::Provider::HTTP::Providers::Anthropic::Streaming)
