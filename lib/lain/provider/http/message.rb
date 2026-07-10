# frozen_string_literal: true

require_relative "content"
require_relative "error"
require_relative "tokens"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/message.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# Leak site 8 (message.rb:106 -- RubyLLM.models.find(model_id) in
# #model_info): deleted. Cost accounting is `Lain::Usage`'s job. `#cost`
# went with it -- it existed only to call `#model_info` and build a
# `RubyLLM::Cost` priced off the (also not vendored) Models registry, so
# keeping it would have been a method that always raised.
#
# `#normalize_content`'s Hash branch dropped the second `Content.new` argument
# now that Content is text-only (leak site 9, see content.rb): upstream passed
# the whole Hash through as an attachments list.

module Lain
  class Provider
    module HTTP
      # One message in a chat conversation: the shape both the vendored
      # `chat.rb`/`tools.rb` payload renderers and `StreamAccumulator` build.
      class Message
        ROLES = %i[system user assistant tool].freeze

        attr_reader :role, :model_id, :tool_calls, :tool_call_id, :raw, :thinking, :tokens
        attr_writer :content

        def initialize(options = {})
          @role = options.fetch(:role).to_sym
          @tool_calls = options[:tool_calls]
          @content = normalize_content(options.fetch(:content), role: @role, tool_calls: @tool_calls)
          @model_id = options[:model_id]
          @tool_call_id = options[:tool_call_id]
          @tokens = options[:tokens] || build_tokens(options)
          @raw = options[:raw]
          @thinking = options[:thinking]

          ensure_valid_role
        end

        def content
          @content.is_a?(Content) && @content.text ? @content.text : @content
        end

        def tool_call?
          !tool_calls.nil? && !tool_calls.empty?
        end

        def tool_result?
          !tool_call_id.nil? && !tool_call_id.empty?
        end

        def tool_results
          content if tool_result?
        end

        def input_tokens
          tokens&.input
        end

        def output_tokens
          tokens&.output
        end

        def cached_tokens
          tokens&.cached
        end

        def cache_creation_tokens
          tokens&.cache_creation
        end

        def cache_read_tokens
          tokens&.cache_read
        end

        def cache_write_tokens
          tokens&.cache_write
        end

        def thinking_tokens
          tokens&.thinking
        end

        def reasoning_tokens
          tokens&.thinking
        end

        def to_h
          {
            role: role,
            content: content,
            model_id: model_id,
            tool_calls: tool_calls,
            tool_call_id: tool_call_id,
            thinking: thinking&.text,
            thinking_signature: thinking&.signature
          }.merge(tokens ? tokens.to_h : {}).compact
        end

        def instance_variables
          super - [:@raw]
        end

        private

        def build_tokens(options)
          Tokens.build(
            input: options[:input_tokens],
            output: options[:output_tokens],
            cached: options[:cached_tokens],
            cache_creation: options[:cache_creation_tokens],
            thinking: options[:thinking_tokens],
            reasoning: options[:reasoning_tokens]
          )
        end

        def normalize_content(content, role:, tool_calls:)
          return "" if role == :assistant && content.nil? && tool_calls && !tool_calls.empty?

          case content
          when String then Content.new(content)
          when Hash then Content.new(content[:text])
          else content
          end
        end

        def ensure_valid_role
          raise InvalidRoleError, "Expected role to be one of: #{ROLES.join(", ")}" unless ROLES.include?(role)
        end
      end
    end
  end
end
