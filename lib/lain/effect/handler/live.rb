# frozen_string_literal: true

module Lain
  module Effect
    class Handler
      # Interprets a {Effect::ToolCall} by actually running the tool the env
      # carries.
      #
      # It holds no {Lain::Toolset} and resolves no name: {Agent::ToolRunner}
      # resolves the tool and hands that object to every layer of the stack and
      # then to this, calling it only if the name still resolves to that same
      # object. What a gate authorized is what runs here as long as the gate is
      # the LAST layer before the interpreter -- a guarantee of position, since
      # a layer after it could rewrite the call it approved. A name the toolset
      # does not hold arrives as {Toolset::Unheld}, which refuses by name.
      #
      # This is where correctness gate 3 is enforced. A tool that raises must
      # never propagate past the loop, so every run is wrapped: any
      # `StandardError` becomes a {Tool::Result} with `is_error: true`. The
      # raising happens honestly inside the tool (contracts stay Eiffel-strict);
      # the *conversion* happens here, once, at the boundary the loop trusts.
      #
      # A tool's second argument is a {Tool::Invocation}, built here from the
      # effect plus the injected `channel` -- never the bare context the env
      # threads through. That is what lets Tools::Bash attribute its
      # `live_stdout` bytes to the exact `tool_use_id` that asked for them.
      class Live < Handler
        # @param channel [Lain::Channel] where tool output is attributed; defaults
        #   to a Null Object so a deployment with no live consumer needs no guard
        def initialize(channel: Channel::Null.instance)
          super()
          @channel = channel
        end

        private

        # The tool is fetched OUTSIDE the rescue below: an env with no `:tool`
        # is a wiring defect, and converting its KeyError into a tool_result
        # would hand the model a sentence about our plumbing.
        def interpret(effect, env)
          invocation = Tool::Invocation.new(tool_use_id: effect.tool_use_id, context: env[:context], channel: @channel)
          run(env.fetch(:tool), effect.input, invocation)
        end

        def run(tool, input, invocation)
          tool.call(input, invocation)
        rescue StandardError => e
          # Correctness gate 3: a failing tool returns a tool_result with
          # is_error: true; it is never dropped and never raised past the loop.
          #
          # The wire text carries the exception's OWN message and nothing else --
          # no `#{e.class}` prefix. That class name is a Ruby implementation
          # detail the model reads as noise on every ordinary refusal, and
          # {Tool::Bounds.ceiling}'s comment flags the sharper version of the
          # same hazard: a class-prefixed string is one hop from leaking bytes a
          # refusal exists to withhold. `ContractViolation` and `InvalidInput`
          # are the two a tool subclass structurally cannot rescue (raised around
          # `#perform` by {Tool#call}), so their own messages are what a reader
          # actually sees. An unexpected error's class is genuinely lost here and
          # is not journaled: `Live`'s only outlet is a view channel that never
          # reaches the journal.
          Tool::Result.error(e.message)
        end
      end
    end
  end
end
