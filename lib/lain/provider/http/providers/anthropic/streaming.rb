# frozen_string_literal: true

require "json"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/providers/anthropic/streaming.rb,
# verbatim apart from RubyLLM:: -> Lain::Provider::HTTP::.
#
# This module only turns an already-parsed SSE data Hash into a {Chunk}; it
# does no I/O and needs no SSE parser of its own. `stream_url`, `build_chunk`,
# and `parse_streaming_error` are the three universal streaming hooks every
# vendored provider defines (see docs/porting-providers.md); the base
# `RubyLLM::Streaming` module that would call them over the wire is NOT
# vendored (see provider.rb's header) because it requires the
# `event_stream_parser` gem, which is not a Lain dependency yet. Vendoring
# this module now means nothing has to change here once that lands.
#
# `extract_model_id`/`extract_input_tokens`/`extract_output_tokens`/
# `extract_cached_tokens`/`extract_cache_creation_tokens` are folded in here
# from upstream's `providers/anthropic/models.rb`, which `build_chunk`
# depends on but which is otherwise all model-registry code we do not
# vendor (`models_url`, `parse_list_models_response` -> `Model::Info`, part
# of leak site 7's `Models` include). These five methods only dig token
# counts and a model id out of an already-parsed streaming Hash -- no
# registry involved -- so they moved to their only caller instead of
# resurrecting a "Models" module for five leaf methods.

module Lain
  class Provider
    module HTTP
      module Providers
        class Anthropic
          # Turns one parsed SSE event Hash into a Chunk. `extract_content_delta`,
          # `extract_thinking_delta`, `extract_signature_delta`, and `json_delta?`
          # are Anthropic-specific -- they read Anthropic's `delta.type` -- and
          # deliberately live here rather than being promoted into shared code.
          module Streaming
            private

            def stream_url
              completion_url
            end

            def build_chunk(data)
              delta_type = data.dig("delta", "type")

              Chunk.new(
                role: :assistant,
                model_id: extract_model_id(data),
                content: extract_content_delta(data, delta_type),
                thinking: chunk_thinking(data, delta_type),
                tool_calls: extract_tool_calls(data),
                **chunk_usage(data)
              )
            end

            def chunk_thinking(data, delta_type)
              Thinking.build(text: extract_thinking_delta(data, delta_type),
                             signature: extract_signature_delta(data, delta_type))
            end

            def chunk_usage(data)
              {
                input_tokens: extract_input_tokens(data),
                output_tokens: extract_output_tokens(data),
                cached_tokens: extract_cached_tokens(data),
                cache_creation_tokens: extract_cache_creation_tokens(data)
              }
            end

            def extract_content_delta(data, delta_type)
              data.dig("delta", "text") if delta_type == "text_delta"
            end

            def extract_thinking_delta(data, delta_type)
              data.dig("delta", "thinking") if delta_type == "thinking_delta"
            end

            def extract_signature_delta(data, delta_type)
              data.dig("delta", "signature") if delta_type == "signature_delta"
            end

            def json_delta?(data)
              data["type"] == "content_block_delta" && data.dig("delta", "type") == "input_json_delta"
            end

            def extract_model_id(data)
              data.dig("message", "model")
            end

            def extract_input_tokens(data)
              data.dig("message", "usage", "input_tokens")
            end

            def extract_output_tokens(data)
              data.dig("message", "usage", "output_tokens") || data.dig("usage", "output_tokens")
            end

            def extract_cached_tokens(data)
              data.dig("message", "usage", "cache_read_input_tokens") || data.dig("usage", "cache_read_input_tokens")
            end

            def extract_cache_creation_tokens(data)
              direct = data.dig("message", "usage", "cache_creation_input_tokens") ||
                       data.dig("usage", "cache_creation_input_tokens")
              return direct if direct

              breakdown = data.dig("message", "usage", "cache_creation") || data.dig("usage", "cache_creation")
              return unless breakdown.is_a?(Hash)

              breakdown.values.compact.sum
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
