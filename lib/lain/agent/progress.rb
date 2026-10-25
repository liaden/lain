# frozen_string_literal: true

module Lain
  class Agent
    # Stops a run that is going round in a circle. A step is a tool call paired
    # with what it returned. Two shapes: the same step `repeats` times in a row,
    # and `stale_steps` steps whose newer half only repeats steps the older half
    # already took. A nil threshold switches that shape off.
    #
    # Reads a fixed number of the newest turns, stopping at the latest human
    # turn, so each ask starts with a clean window and the cost stays flat on a
    # session of any length.
    Progress = Data.define(:repeats, :stale_steps) do
      # @param timeline [#ancestors] the conversation so far, newest turn first
      # @return [nil]
      # @raise [Lain::Budget::Exceeded] with kind :stuck
      def check!(timeline)
        steps = recent_steps(timeline)
        repeated_step(steps)
        stale_steps_in(steps)
        nil
      end

      private

      def recent_steps(timeline)
        limit = [repeats, stale_steps].compact.max
        return [] unless limit

        # Any user text turn resets the window: a compaction summary or a steering message means
        # what came before is summarised away or redirected; the iteration ceiling still bounds an escape.
        turns = timeline.ancestors.lazy.first((2 * limit) + Progress::MARGIN).take_while { |turn| !human?(turn) }
        turns.each_cons(2).select { |result, call| answers?(result, call) }.map { |result, call| step(call, result) }
      end

      def repeated_step(steps)
        return unless repeats

        newest = steps.first(repeats)
        return unless newest.size == repeats && newest.uniq.one?

        raise Budget::Exceeded.new("#{newest.first.first.first.first} called #{repeats} times with the same input " \
                                   "and result", kind: :stuck)
      end

      def stale_steps_in(steps)
        return unless stale_steps

        window = steps.first(stale_steps).reverse
        return unless window.size == stale_steps && nothing_new_in_newer_half?(window)

        raise Budget::Exceeded.new("#{stale_steps} steps brought nothing new", kind: :stuck)
      end

      def nothing_new_in_newer_half?(window)
        half = stale_steps / 2
        older = window.take(half)
        window.drop(half).all? { |step| older.include?(step) }
      end

      def human?(turn) = turn.role.to_s == "user" && blocks(turn, "tool_result").empty?

      def answers?(result, call) = blocks(result, "tool_result").any? && blocks(call, "tool_use").any?

      def step(call, result)
        [blocks(call, "tool_use").map { |block| [block["name"], block["input"]] },
         Canonical.digest(blocks(result, "tool_result").map { |block| block["content"] })]
      end

      def blocks(turn, type)
        content = turn.content
        content.is_a?(Array) ? content.select { |block| block["type"] == type } : []
      end
    end

    Progress::MARGIN = 4
    Progress::DEFAULT = Progress.new(repeats: 3, stale_steps: 8)
  end
end
