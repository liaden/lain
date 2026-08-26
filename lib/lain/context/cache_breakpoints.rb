# frozen_string_literal: true

module Lain
  class Context
    # Places prompt-cache breakpoints on the message list: the final block of
    # the final message, plus intermediate blocks roughly every `every`
    # blocks, so a long agentic turn never drifts outside Anthropic's
    # lookback window. `"cache" => true` is Lain's neutral marker; rendering
    # it as `cache_control` is the Provider's job.
    #
    # Anthropic rejects a request carrying more than 4 `cache_control` blocks
    # total. Placement used to be uncapped here AND repeated independently by
    # {Provider::AnthropicEncoding}, so a long enough session 400d; it is now
    # owned here alone, budgeted, and the encoder is pure translation.
    #
    # This combinator only ever sees the message list, never the system prompt,
    # so it cannot observe whether `Context#cache_marked` (the ONE other place a
    # marker gets placed) spent a slot on this render. It reserves that slot
    # unconditionally -- worst case one slot goes unused, where guessing wrong
    # is a 400.
    class CacheBreakpoints < Combinator
      include Declarative

      # Anthropic looks back a bounded number of content blocks when matching a
      # cache breakpoint. Agentic turns pile up tool_use/tool_result pairs and
      # blow past it easily, so intermediate breakpoints are placed well inside
      # the window rather than at its edge.
      LOOKBACK_BLOCKS = 20
      EVERY = 15
      CAP = 4

      # `every` must stay strictly inside the lookback window, and `cap` must be
      # a positive marker budget. The DEFAULTS live here too, beside the rules
      # that judge them rather than in the constructor signature, so there is
      # nowhere for a signature default and a declared default to disagree.
      declare do
        attribute :every, default: EVERY
        attribute :lookback, default: LOOKBACK_BLOCKS
        attribute :cap, default: CAP
        validates :cap, numericality: { greater_than: 0, message: "must be positive, got %<value>s" }
        validate do
          errors.add(:every, "(#{every}) must stay inside the lookback window (#{lookback})") if
            every && lookback && every >= lookback
        end
      end

      # `cap: 1` is legal and yields ZERO message markers -- the reserved system
      # slot consumes the whole budget, so not even the last block is marked.
      # The degrade is silent by design: #call must stay a pure function of the
      # message list, so there is no Sink or Channel to signal through. This
      # comment and the spec pinning the behavior are the loud part.
      #
      # `**attrs`, not the three keywords spelled out, so the declared defaults
      # above have no second copy here. The cost is that a typo'd keyword raises
      # {Lain::Declarative::UndeclaredAttribute} rather than Ruby's `unknown
      # keyword` -- a programmer error either way, never a refused value.
      #
      # @param attrs [Hash] `every:`, `lookback:`, `cap:` -- each defaulted above
      def initialize(**attrs)
        settled = self.class.settle!(**attrs)

        super()
        @every = settled.fetch(:every)
        @message_budget = settled.fetch(:cap) - 1
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

      # Every candidate breakpoint: the final message, plus one roughly every
      # `every` blocks. #call keeps only the most recent `@message_budget` of
      # them, dropping the oldest first. That is safe -- on a miss, the write at
      # the earliest RETAINED marker covers the whole prefix before it, so the
      # cost is coarser partial-hit granularity, not correctness.
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
