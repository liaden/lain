# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "message"
require_relative "stream_accumulator/think_tag_scanner"
require_relative "stream_accumulator/tool_call_accumulator"
require_relative "thinking"
require_relative "tokens"
require_relative "tool_call"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/stream_accumulator.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# Leak site 2 (stream_accumulator.rb:28,34,80 -- RubyLLM.logger.debug{} if
# RubyLLM.config.log_stream_debug): both the global logger and the global
# Configuration read are gone. `#initialize` now takes an injected
# `Lain::Sink` (default `Sink::Null`) and a `debug:` boolean (default
# false) instead of reading `RubyLLM.config.log_stream_debug` off a
# singleton -- this class already takes no other global state, and reading
# one would be the one exception.
#
# Upstream is 218 lines in one class; ported as-is it clears the default
# `Metrics/ClassLength` (100) with no loosening allowed. `<think>` tag
# scanning and streamed tool-call-fragment reassembly are each a real,
# separate responsibility, so they are extracted to
# {ThinkTagScanner}/{ToolCallAccumulator} rather than disabled away --
# behavior, including the chunk-boundary reassembly this class exists to get
# right, is unchanged.
#
# This is the ONLY thing in the vendored slice that exercises `input_json_delta`
# chunk-boundary reassembly without a live connection -- see
# `spec/lain/provider/http/stream_accumulator_spec.rb`, ported near-verbatim.

module Lain
  class Provider
    module HTTP
      # Assembles a sequence of streamed Chunks into one complete Message.
      class StreamAccumulator
        attr_reader :content, :model_id

        def initialize(sink: Sink::Null.new, debug: false)
          @sink = sink
          @debug = debug
          @think_scanner = ThinkTagScanner.new
          @tool_call_accumulator = ToolCallAccumulator.new(sink: sink, debug: debug)
          reset_buffers!
          reset_token_counts!
        end

        def add(chunk)
          @sink.puts(chunk.inspect) if @debug
          @model_id ||= chunk.model_id

          handle_chunk_content(chunk)
          append_thinking_from_chunk(chunk)
          count_tokens chunk
          @sink.puts(inspect) if @debug
        end

        def tool_calls
          @tool_call_accumulator.tool_calls
        end

        def to_message(response)
          Message.new(
            role: :assistant,
            content: content.empty? ? nil : content,
            thinking: built_thinking,
            tokens: built_tokens,
            model_id: model_id,
            tool_calls: @tool_call_accumulator.to_h,
            raw: response
          )
        end

        private

        def reset_buffers!
          @content = +""
          @thinking_text = +""
          @thinking_signature = nil
        end

        def reset_token_counts!
          @input_tokens = nil
          @output_tokens = nil
          @cached_tokens = nil
          @cache_creation_tokens = nil
          @thinking_tokens = nil
        end

        def built_thinking
          Thinking.build(text: @thinking_text.empty? ? nil : @thinking_text, signature: @thinking_signature)
        end

        def built_tokens
          Tokens.build(input: @input_tokens, output: @output_tokens, cached: @cached_tokens,
                       cache_creation: @cache_creation_tokens, thinking: @thinking_tokens)
        end

        def count_tokens(chunk)
          @input_tokens = chunk.input_tokens if chunk.input_tokens
          @output_tokens = chunk.output_tokens if chunk.output_tokens
          @cached_tokens = chunk.cached_tokens if chunk.cached_tokens
          @cache_creation_tokens = chunk.cache_creation_tokens if chunk.cache_creation_tokens
          @thinking_tokens = chunk.thinking_tokens if chunk.thinking_tokens
        end

        def handle_chunk_content(chunk)
          return @tool_call_accumulator.add(chunk.tool_calls) if chunk.tool_call?

          content_text = chunk.content || ""
          content_text.is_a?(String) ? append_text_with_thinking(content_text) : (@content << content_text.to_s)
        end

        def append_text_with_thinking(text)
          content_chunk, thinking_chunk = @think_scanner.call(text)
          @content << content_chunk
          @thinking_text << thinking_chunk if thinking_chunk
        end

        def append_thinking_from_chunk(chunk)
          thinking = chunk.thinking
          return unless thinking

          @thinking_text << thinking.text.to_s if thinking.text
          # Not `||=`: that reads to Naming/MemoizedInstanceVariableName as
          # memoizing a `@thinking_signature` method that does not exist. A
          # signature only ever arrives once per stream (Anthropic sends it on
          # the thinking block's final delta), so the first non-nil value wins.
          @thinking_signature = thinking.signature if @thinking_signature.nil?
        end
      end
    end
  end
end
