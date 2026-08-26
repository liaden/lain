# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/message.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# `#model_info` and `#cost` are deleted: cost accounting is `Lain::Usage`'s job,
# and both existed only to price against the Models registry this slice does not
# vendor -- so keeping them would have been methods that always raised.
#
# `#normalize_content`'s Hash branch dropped the second `Content.new` argument
# now that Content is text-only; upstream passed the whole Hash through as an
# attachments list.

module Lain
  class Provider
    module HTTP
      # One message in a chat conversation: the shape both the vendored
      # `chat.rb`/`tools.rb` payload renderers and `StreamAccumulator` build.
      class Message
        ROLES = %i[system user assistant tool].freeze

        attr_reader :role, :model_id, :tool_calls, :tool_call_id, :raw, :thinking, :tokens
        attr_writer :content

        # @param options [Hash] every field of the message, as the vendored
        #   payload renderers and `StreamAccumulator` build it
        # @option options [Symbol, String] :role required; one of {ROLES}
        # @option options [String, Hash, Content] :content required; normalized to
        #   a {Content}, and permitted to be nil only on an assistant message
        #   that carries tool calls
        # @option options [Array<ToolCall>, nil] :tool_calls the calls this
        #   assistant message asks for
        # @option options [String, nil] :tool_call_id the call a tool result answers
        # @option options [String, nil] :model_id the model that produced it
        # @option options [Tokens, nil] :tokens a prebuilt count; when absent one
        #   is built from the per-field counts {#build_tokens} names
        # @option options [Object, nil] :raw the untouched wire object, excluded
        #   from `#instance_variables` so it never reaches an inspect line
        # @option options [Thinking, nil] :thinking the extended-thinking block
        # @raise [ArgumentError] when :role is not one of {ROLES}
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

        # @param options [Hash] {#initialize}'s own options hash
        # @option options [Integer, nil] :input_tokens prompt tokens
        # @option options [Integer, nil] :output_tokens completion tokens
        # @option options [Integer, nil] :cached_tokens tokens served from cache
        # @option options [Integer, nil] :cache_creation_tokens tokens written to cache
        # @option options [Integer, nil] :thinking_tokens extended-thinking tokens
        # @option options [Integer, nil] :reasoning_tokens reasoning tokens
        # @return [Tokens, nil] nil when every count is absent
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
