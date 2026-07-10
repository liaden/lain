# frozen_string_literal: true

# Split from chat.rb -- see that file's header. Response parsing: turning
# Anthropic's completion response body into a {Message}.
#
# `build_message`'s upstream signature was six positional parameters
# (`data, content, thinking, thinking_signature, tool_use_blocks, response`),
# past this project's default `Metrics/ParameterLists` (5). This project's
# `.rubocop.yml` sets `CountKeywordArgs: false`, so converting everything but
# `data` to keywords -- and building the pre-parsed {Thinking} before calling
# it, rather than passing text and signature separately -- clears the cop
# without changing what gets sent to {Message#initialize}.

module Lain
  class Provider
    module HTTP
      module Providers
        class Anthropic
          # Reopened from chat.rb to add response parsing; see that file's
          # header.
          module Chat
            module_function

            def parse_completion_response(response)
              data = response.body
              content_blocks = data["content"] || []

              build_message(
                data,
                text: extract_text_content(content_blocks),
                thinking: Thinking.build(text: extract_thinking_content(content_blocks),
                                         signature: extract_thinking_signature(content_blocks)),
                tool_use_blocks: Tools.find_tool_uses(content_blocks),
                response: response
              )
            end

            def extract_text_content(blocks)
              blocks.select { |c| c["type"] == "text" }.map { |c| c["text"] }.join
            end

            def extract_thinking_content(blocks)
              thoughts = blocks.select { |c| c["type"] == "thinking" }.map { |c| c["thinking"] || c["text"] }.join
              thoughts.empty? ? nil : thoughts
            end

            def extract_thinking_signature(blocks)
              thinking_block = blocks.find { |c| c["type"] == "thinking" } ||
                               blocks.find { |c| c["type"] == "redacted_thinking" }
              thinking_block&.dig("signature") || thinking_block&.dig("data")
            end

            def build_message(data, text:, thinking:, tool_use_blocks:, response:)
              Message.new(
                role: :assistant,
                content: text,
                thinking: thinking,
                tool_calls: Tools.parse_tool_calls(tool_use_blocks),
                model_id: data["model"],
                raw: response,
                **usage_fields(data["usage"] || {})
              )
            end

            def usage_fields(usage)
              {
                input_tokens: usage["input_tokens"],
                output_tokens: usage["output_tokens"],
                cached_tokens: usage["cache_read_input_tokens"],
                cache_creation_tokens: cache_creation_tokens(usage),
                thinking_tokens: thinking_tokens(usage)
              }
            end

            def cache_creation_tokens(usage)
              return usage["cache_creation_input_tokens"] unless usage["cache_creation_input_tokens"].nil?
              return unless usage["cache_creation"].is_a?(Hash)

              usage["cache_creation"].values.compact.sum
            end

            def thinking_tokens(usage)
              usage.dig("output_tokens_details", "thinking_tokens") ||
                usage.dig("output_tokens_details", "reasoning_tokens") ||
                usage["thinking_tokens"] ||
                usage["reasoning_tokens"]
            end
          end
        end
      end
    end
  end
end
