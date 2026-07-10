# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/providers/anthropic/tools.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# Leak site 11 (tools.rb:69 -- RubyLLM::Tool::SchemaDefinition.from_parameters):
# we do not vendor RubyLLM::Tool, so `.function_for` now accepts any duck
# responding to `#name`, `#description`, `#input_schema` -- exactly
# `Lain::Tool`. The `params_schema` / `parameters` / `provider_params` upstream
# fell back through are RubyLLM::Tool-specific and have no Lain::Tool
# equivalent, so the merge-provider-params step is gone with them.
#
# Also gains `.format_content`, the text-only remainder of the RubyLLM::Media
# module (leak site 7, not vendored): once Content carries no attachments
# (leak site 9), formatting collapses to "wrap a String/Hash/Array/Content as
# a single text block," which both this module and chat.rb need.

module Lain
  class Provider
    module HTTP
      module Providers
        class Anthropic
          # Tool-call formatting and parsing for the Anthropic wire format.
          module Tools
            module_function

            def find_tool_uses(blocks)
              blocks.select { |c| c["type"] == "tool_use" }
            end

            def format_tool_result(msg)
              {
                role: "user",
                content: msg.content.is_a?(Content::Raw) ? msg.content.value : [format_tool_result_block(msg)]
              }
            end

            def format_tool_use_block(tool_call)
              { type: "tool_use", id: tool_call.id, name: tool_call.name, input: tool_call.arguments }
            end

            def append_formatted_content(content_blocks, content)
              formatted_content = format_content(content)
              if formatted_content.is_a?(Array)
                content_blocks.concat(formatted_content)
              else
                content_blocks << formatted_content
              end
            end

            def format_tool_result_block(msg)
              content = msg.content
              content = "(no output)" if content.nil? || (content.respond_to?(:empty?) && content.empty?)

              { type: "tool_result", tool_use_id: msg.tool_call_id, content: format_content(content) }
            end

            # The stand-in for RubyLLM::Media#format_content (leak site 7):
            # with no Attachment to branch on, a Content renders to at most one
            # text block.
            def format_content(content)
              return content.value if content.is_a?(Content::Raw)
              return [format_text(content.to_json)] if content.is_a?(Hash) || content.is_a?(Array)
              return [format_text(content)] unless content.is_a?(Content)

              content.text ? [format_text(content.text)] : []
            end

            def format_text(text)
              { type: "text", text: text }
            end

            # @param tool [#name, #description, #input_schema] a Lain::Tool
            def function_for(tool)
              { name: tool.name, description: tool.description,
                input_schema: tool.input_schema || default_input_schema }
            end

            def extract_tool_calls(data)
              if json_delta?(data)
                extract_tool_call_delta(data)
              elsif content_block_start?(data)
                extract_tool_call_start(data)
              else
                parse_tool_calls(data["content_block"])
              end
            end

            def extract_tool_call_delta(data)
              { data["index"] => ToolCall.new(id: nil, name: nil, arguments: data.dig("delta", "partial_json")) }
            end

            def extract_tool_call_start(data)
              tool_calls = parse_tool_calls(data["content_block"])
              return tool_calls if tool_calls.nil? || data["index"].nil?

              { data["index"] => tool_calls.values.first }
            end

            def content_block_start?(data)
              data["type"] == "content_block_start"
            end

            def parse_tool_calls(content_blocks)
              return nil if content_blocks.nil?

              content_blocks = [content_blocks] unless content_blocks.is_a?(Array)

              tool_calls = content_blocks.select { |block| block && block["type"] == "tool_use" }.to_h do |block|
                [block["id"], ToolCall.new(id: block["id"], name: block["name"], arguments: block["input"])]
              end

              tool_calls.empty? ? nil : tool_calls
            end

            def default_input_schema
              { "type" => "object", "properties" => {}, "required" => [], "additionalProperties" => false,
                "strict" => true }
            end

            def build_tool_choice(tool_prefs)
              tool_choice = tool_prefs[:choice] || :auto
              calls_in_response = tool_prefs[:calls]

              { type: tool_choice_type(tool_choice) }.tap do |tc|
                tc[:name] = tool_choice if tc[:type] == :tool
                unless tc[:type] == :none || calls_in_response.nil?
                  tc[:disable_parallel_tool_use] = calls_in_response == :one
                end
              end
            end

            def tool_choice_type(tool_choice)
              case tool_choice
              when :auto, :none then tool_choice
              when :required then :any
              else :tool
              end
            end
          end
        end
      end
    end
  end
end
