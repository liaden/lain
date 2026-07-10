# frozen_string_literal: true

require_relative "../effect"
require_relative "../middleware"

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
        response.tool_uses.map { |tool_use| result_block(tool_use, context) }
      end

      private

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
        env = @middleware.call({ effect: effect, context: context }, &@handler.to_app)
        env.fetch(:result)
      end
    end
  end
end
