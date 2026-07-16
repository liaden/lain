# frozen_string_literal: true

require "async"

module Lain
  class Agent
    # Turns an assistant turn's tool_use blocks into the tool_result blocks that
    # answer them.
    #
    # Split out of the Agent because it answers a different question. The Agent
    # decides *when* to run tools; this decides *how* -- building the Effect,
    # threading it through the tool middleware, and shaping the outcome into wire
    # blocks. Correctness gates 3, 4, and 5 all live in that shaping, and they are
    # easier to see when they are not interleaved with the state machine.
    #
    # Gate 2 stays with the Agent, because "all results in ONE user turn" is a
    # statement about the Timeline, not about any individual tool.
    class ToolRunner
      def initialize(handler:, middleware: Middleware::Stack.new)
        @handler = handler
        @middleware = middleware
      end

      # @return [Array<Hash>] one tool_result block per tool_use, in order
      def run(response, context:)
        uses = response.tool_uses
        gatherable?(uses) ? gather(uses, context) : sequential(uses, context)
      end

      private

      # The default, order-preserving map: each tool_use resolved before the next.
      # Load-bearing for tools that make no parallelism claim -- gate 2 is an
      # ordering over the RETURNED blocks, and a sequential map trivially honours
      # it. Everything that is not a whole turn of parallel_safe? tools stays here.
      def sequential(uses, context)
        uses.map { |tool_use| result_block(tool_use, context) }
      end

      # Fan the tool_uses out as sibling Async tasks, then gather their results in
      # tool_use order. Gate 2 is unmoved: `map(&:wait)` restores the schedule the
      # model asked for however the tasks actually finished, so out-of-order
      # completion still lands in ONE user turn ordered by tool_use. A stop of the
      # hosting task cancels the siblings as one tree (structured cancellation), so
      # an interrupt mid-fan-out returns nothing to commit rather than a partial
      # set. `Sync` joins the Agent's reactor when there is one and spins one up
      # otherwise, so a direct caller outside a reactor works too.
      def gather(uses, context)
        Sync do |task|
          uses.map { |tool_use| task.async { result_block(tool_use, context) } }
              .map(&:wait)
        end
      end

      # Concurrency is opted into per tool AND only for a whole turn of them: a
      # single unsafe tool_use keeps the entire turn sequential, so a tool that
      # made no parallelism claim is never run alongside another. One tool_use has
      # nothing to gather, so it stays sequential too.
      def gatherable?(uses)
        uses.size > 1 && uses.all? { |tool_use| parallel_safe?(tool_use) }
      end

      # Resolve the named tool against the same chain the dispatch will run
      # against ({Effect::Handler#tool_named}); a name the chain does not hold
      # (a Mock handler, an unknown tool) is treated as not parallel-safe.
      def parallel_safe?(tool_use)
        @handler.tool_named(tool_use.fetch("name"))&.parallel_safe? || false
      end

      def result_block(tool_use, context)
        result = dispatch(tool_use, context)
        {
          "type" => "tool_result",
          # Gate 4: the id must match the tool_use that asked for it.
          "tool_use_id" => tool_use.fetch("id"),
          "content" => result.content,
          # Gate 3: a failed tool is reported, never dropped and never raised past
          # the loop. Handler::Live is where the conversion happens.
          "is_error" => result.error?
        }
      end

      def dispatch(tool_use, context)
        effect = Effect::ToolCall.new(
          tool_use_id: tool_use.fetch("id"),
          name: tool_use.fetch("name"),
          # Gate 5: a parsed object, never a serialized JSON string. The Provider
          # guarantees this even on the streaming path, where the wire hands back
          # `input` as a raw String.
          input: tool_use.fetch("input")
        )
        @middleware.call({ effect:, context: }, &@handler.to_app).result
      end
    end
  end
end
