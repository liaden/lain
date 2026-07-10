# frozen_string_literal: true

require_relative "base"

module Lain
  class Context
    # Places prompt-cache breakpoints on the message list: the final block of
    # the final message, plus intermediate blocks roughly every `every`
    # blocks, so a long agentic turn never drifts outside Anthropic's
    # lookback window. `"cache" => true` is Lain's neutral marker; rendering
    # it as `cache_control` is the Provider's job.
    #
    # This is the relocated body of what used to be Context#mark_cache_breakpoints
    # / #mark_last_block -- moved here rather than duplicated, since the
    # combinator IS the formalization of that behavior (3c-2.4).
    class CacheBreakpoints < Base
      # Anthropic looks back a bounded number of content blocks when matching
      # a cache breakpoint. Agentic turns, which pile up tool_use/tool_result
      # pairs, blow past it easily, so intermediate breakpoints are placed
      # well inside the window rather than at its edge.
      LOOKBACK_BLOCKS = 20
      EVERY = 15

      def initialize(every: EVERY, lookback: LOOKBACK_BLOCKS)
        raise ArgumentError, "every (#{every}) must stay inside the lookback window (#{lookback})" if every >= lookback

        super()
        @every = every
        freeze
      end

      def call(messages)
        return messages if messages.empty?

        last_index = messages.size - 1
        blocks_since = 0
        messages.each_with_index.map do |message, index|
          blocks_since += message["content"].size
          breakpoint = index == last_index || blocks_since >= @every
          blocks_since = 0 if breakpoint
          breakpoint ? mark_last_block(message) : message
        end
      end

      def requires
        [:prompt_caching].freeze
      end

      private

      def mark_last_block(message)
        content = message["content"]
        return message if content.empty?

        marked_tail = content.last.merge("cache" => true)
        { "role" => message["role"], "content" => content[0..-2] + [marked_tail] }
      end
    end
  end
end
