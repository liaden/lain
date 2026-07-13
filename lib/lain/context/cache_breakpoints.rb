# frozen_string_literal: true

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
    #
    # == The cap (CE-1)
    #
    # Anthropic rejects a request carrying more than 4 `cache_control` blocks
    # total. This combinator used to place one every `every` blocks with no
    # upper bound, and {Provider::AnthropicEncoding} independently placed its
    # own stride breakpoints on top -- two layers, neither capped, so a long
    # enough session 400d. Placement is now owned here alone, budgeted, and
    # the encoder is pure translation.
    #
    # This combinator only ever sees the message list, never the system
    # prompt, so it cannot observe whether `Context#cache_marked_system` (the
    # ONE other place a marker gets placed) spent a slot on this render. It
    # reserves that slot unconditionally -- always budgeting `cap - 1` for
    # messages -- because reserving is safe (worst case, one slot goes
    # unused) and guessing wrong is not (worst case, a 400).
    class CacheBreakpoints < Base
      # Anthropic looks back a bounded number of content blocks when matching
      # a cache breakpoint. Agentic turns, which pile up tool_use/tool_result
      # pairs, blow past it easily, so intermediate breakpoints are placed
      # well inside the window rather than at its edge.
      LOOKBACK_BLOCKS = 20
      EVERY = 15
      CAP = 4

      # `cap: 1` is legal and yields ZERO message markers -- the reserved
      # system slot consumes the whole budget, so not even the last block is
      # marked. The degrade is silent by design: this combinator is pure
      # (#call must stay a function of the message list; no Sink, no
      # Channel), so there is no runtime channel to signal through without
      # breaking that contract. This comment and the spec pinning the
      # behavior are the loud part.
      def initialize(every: EVERY, lookback: LOOKBACK_BLOCKS, cap: CAP)
        raise ArgumentError, "every (#{every}) must stay inside the lookback window (#{lookback})" if every >= lookback
        raise ArgumentError, "cap (#{cap}) must be positive" unless cap.positive?

        super()
        @every = every
        @message_budget = cap - 1
        freeze
      end

      def call(messages)
        return messages if messages.empty?

        marked = breakpoint_indices(messages).last(@message_budget)
        messages.each_with_index.map { |message, index| marked.include?(index) ? mark_last_block(message) : message }
      end

      def requires
        [:prompt_caching].freeze
      end

      private

      # Every candidate breakpoint the old, uncapped placement rule would
      # mark: the final message, plus one roughly every `every` blocks.
      # #call then keeps only the most recent `@message_budget` of these --
      # tail-clustered, dropping the oldest first. Dropping an old marker is
      # safe: on a miss, the write at the earliest RETAINED marker covers the
      # whole prefix before it, so the only cost is coarser partial-hit
      # granularity, not correctness.
      def breakpoint_indices(messages)
        last_index = messages.size - 1
        blocks_since = 0
        messages.each_with_index.with_object([]) do |(message, index), indices|
          blocks_since += message["content"].size
          breakpoint = index == last_index || blocks_since >= @every
          indices << index if breakpoint
          blocks_since = 0 if breakpoint
        end
      end

      def mark_last_block(message)
        content = message["content"]
        return message if content.empty?

        marked_tail = content.last.merge("cache" => true)
        { "role" => message["role"], "content" => content[0..-2] + [marked_tail] }
      end
    end
  end
end
