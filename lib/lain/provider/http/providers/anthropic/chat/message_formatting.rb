# frozen_string_literal: true

# Split from chat.rb -- see that file's header. Message-to-wire-block
# formatting: turning one {Message} into the Hash Anthropic's `messages`
# array expects, including the extended-thinking block a `tool_use` or
# plain-text message must carry first when thinking is enabled.

module Lain
  class Provider
    module HTTP
      module Providers
        class Anthropic
          # Reopened from chat.rb to add message-to-wire-block formatting;
          # see that file's header.
          module Chat
            module_function

            def format_message(msg, thinking: nil)
              thinking_enabled = thinking&.enabled?

              if msg.tool_call?
                format_tool_call_with_thinking(msg, thinking_enabled)
              elsif msg.tool_result?
                Tools.format_tool_result(msg)
              else
                format_basic_message_with_thinking(msg, thinking_enabled)
              end
            end

            def format_basic_message_with_thinking(msg, thinking_enabled)
              content_blocks = []

              if msg.role == :assistant && thinking_enabled
                thinking_block = build_thinking_block(msg.thinking)
                content_blocks << thinking_block if thinking_block
              end

              append_formatted_content(content_blocks, msg.content)

              { role: convert_role(msg.role), content: content_blocks }
            end

            def format_tool_call_with_thinking(msg, thinking_enabled)
              return raw_tool_call_message(msg, thinking_enabled) if msg.content.is_a?(Content::Raw)

              content_blocks = prepend_thinking_block([], msg, thinking_enabled)
              append_formatted_content(content_blocks, msg.content) unless msg.content.nil? || msg.content.empty?

              msg.tool_calls.each_value { |tool_call| content_blocks << Tools.format_tool_use_block(tool_call) }

              { role: "assistant", content: content_blocks }
            end

            def raw_tool_call_message(msg, thinking_enabled)
              content_blocks = msg.content.value
              content_blocks = [content_blocks] unless content_blocks.is_a?(Array)
              content_blocks = prepend_thinking_block(content_blocks, msg, thinking_enabled)

              { role: "assistant", content: content_blocks }
            end

            def prepend_thinking_block(content_blocks, msg, thinking_enabled)
              return content_blocks unless thinking_enabled

              thinking_block = build_thinking_block(msg.thinking)
              content_blocks.unshift(thinking_block) if thinking_block

              content_blocks
            end

            def build_thinking_block(thinking)
              return nil unless thinking

              if thinking.text
                { type: "thinking", thinking: thinking.text, signature: thinking.signature }.compact
              elsif thinking.signature
                { type: "redacted_thinking", data: thinking.signature }
              end
            end

            def append_formatted_content(content_blocks, content)
              formatted_content = Tools.format_content(content)
              if formatted_content.is_a?(Array)
                content_blocks.concat(formatted_content)
              else
                content_blocks << formatted_content
              end
            end

            def convert_role(role)
              case role
              when :tool, :user then "user"
              else "assistant"
              end
            end
          end
        end
      end
    end
  end
end
