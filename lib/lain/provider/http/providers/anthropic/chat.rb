# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/providers/anthropic/chat.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::. `append_formatted_content` and
# `build_system_content` called the module-level `Media.format_content` (not
# vendored -- leak site 7); both now call `Tools.format_content` instead,
# which `tools.rb` defines as the text-only remainder of the same method
# (leak site 9: Content carries no attachments to branch on any more).
#
# `parse_completion_response` still flattens every text block into one String
# and keeps only the first thinking block's signature. That is deliberate --
# the porting brief is explicit that this branch must NOT change it. Making
# it retain the full block list is the `transport` branch's first mutation.
#
# Upstream is one 197-line file/module, past this project's default
# `Metrics/ModuleLength` (100) with no loosening allowed. `Chat` is still one
# logical module (`include Anthropic::Chat` in anthropic.rb is unchanged),
# but its four real responsibilities -- payload assembly (here), message-to-
# wire-block formatting, extended-thinking payload construction, and
# response parsing -- are split across four files, each reopening `module
# Chat` and each independently under 100 lines. Ruby modules are reopenable
# on purpose; this is the same pattern ActiveRecord::Base uses across dozens
# of files, not a Metrics dodge.

module Lain
  class Provider
    module HTTP
      module Providers
        class Anthropic
          # Chat/completion payload rendering and response parsing. Split
          # across chat.rb (payload assembly), chat/message_formatting.rb,
          # chat/thinking_payload.rb, and chat/response_parsing.rb -- see the
          # header above.
          module Chat
            module_function

            def completion_url
              "v1/messages"
            end

            def render_payload(messages, tools:, temperature:, model:, stream: false,
                               schema: nil, thinking: nil, tool_prefs: nil)
              tool_prefs ||= {}
              system_messages, chat_messages = separate_messages(messages)
              system_content = build_system_content(system_messages)

              build_base_payload(chat_messages, model, stream, thinking).tap do |payload|
                add_optional_fields(payload, system_content:, tools:, tool_prefs:, temperature:, schema:)
              end
            end

            def separate_messages(messages)
              messages.partition { |msg| msg.role == :system }
            end

            def build_system_content(system_messages)
              return [] if system_messages.empty?

              # Anthropic's `system` parameter accepts an array of text content blocks
              # (each optionally with cache_control); each :system message becomes its
              # own block in the resulting array.
              system_messages.flat_map do |msg|
                content = msg.content
                content.is_a?(Content::Raw) ? content.value : Tools.format_content(content)
              end
            end

            def build_base_payload(chat_messages, model, stream, thinking)
              payload = {
                model: model.id,
                messages: chat_messages.map { |msg| format_message(msg, thinking:) },
                stream: stream,
                max_tokens: model.max_tokens || 4096
              }

              add_thinking_fields(payload, thinking, model)

              payload
            end

            def add_optional_fields(payload, system_content:, tools:, tool_prefs:, temperature:, schema: nil)
              if tools.any?
                payload[:tools] = tools.values.map { |t| Tools.function_for(t) }
                add_tool_choice(payload, tool_prefs)
              end
              payload[:system] = system_content unless system_content.empty?
              payload[:temperature] = temperature unless temperature.nil?
              payload[:output_config] = payload.fetch(:output_config, {}).merge(build_output_config(schema)) if schema
            end

            def add_tool_choice(payload, tool_prefs)
              return if tool_prefs[:choice].nil? && tool_prefs[:calls].nil?

              payload[:tool_choice] = Tools.build_tool_choice(tool_prefs)
            end

            def build_output_config(schema)
              normalized = Utils.deep_dup(schema[:schema])
              normalized.delete(:strict)
              normalized.delete("strict")
              { format: { type: "json_schema", schema: normalized } }
            end
          end
        end
      end
    end
  end
end

require_relative "chat/message_formatting"
require_relative "chat/thinking_payload"
require_relative "chat/response_parsing"
