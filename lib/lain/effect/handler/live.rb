# frozen_string_literal: true

module Lain
  module Effect
    class Handler
      # Interprets effects by actually doing them: dispatches a {Effect::ToolCall}
      # to the tool the {Lain::Toolset} holds under that name and runs it.
      #
      # This is where correctness gate 3 is enforced. A tool that raises must
      # never propagate past the loop, so every dispatch is wrapped: any
      # `StandardError` becomes a {Tool::Result} with `is_error: true`. The
      # raising happens honestly inside the tool (contracts stay Eiffel-strict);
      # the *conversion* happens here, once, at the boundary the loop trusts.
      #
      # Live is the executor of last resort and does not itself gate on approval
      # -- a deployment composes a {Gate} in front of it. So an
      # {Effect::Approval} reaching Live is treated as already-approved,
      # otherwise a stack with no approver would wedge on every gated call.
      #
      # A tool's second argument is a {Tool::Invocation}, built here from the
      # effect plus the injected `channel` -- never the bare context a caller
      # threads through {#call}. That is what lets Tools::Bash attribute its
      # `live_stdout` bytes to the exact `tool_use_id` that asked for them.
      class Live < Handler
        # @param toolset [Lain::Toolset] the capabilities this handler can dispatch
        # @param channel [Lain::Channel] where tool output is attributed; defaults
        #   to a Null Object so a deployment with no live consumer needs no guard
        # @param inner [Lain::Effect::Handler, nil] fallback for other effect kinds
        def initialize(toolset:, channel: Channel::Null.instance, inner: nil)
          super(inner:)
          @toolset = toolset
          @channel = channel
        end

        def handles?(effect) = effect.tool_call? || effect.approval?

        # Dispatch and this lookup read the same `@toolset`, so a decorator that
        # gates via {Handler#tool_named} is guaranteed to consult the map this
        # handler will actually run against.
        def tool_named(name)
          return @toolset.fetch(name) if @toolset.include?(name)

          super
        end

        protected

        # The `case` over class is genuine dispatch on a CLOSED set -- the effect
        # vocabulary is the algebra, and each arm is a distinct interpretation.
        # A `rescue NoMethodError` else-arm was rejected: it would turn an effect
        # this executor genuinely cannot perform into a silent swallow instead of
        # the loud {UnhandledEffect}.
        def perform(effect, context)
          case effect
          when Effect::Approval then call(effect.effect, context)
          when Effect::ToolCall then dispatch(effect, context)
          else raise UnhandledEffect, "#{self.class} cannot perform #{effect.class}"
          end
        end

        private

        def dispatch(effect, context)
          invocation = Tool::Invocation.new(tool_use_id: effect.tool_use_id, context:, channel: @channel)
          @toolset.fetch(effect.name).call(effect.input, invocation)
        rescue Toolset::UnknownTool
          # A tool this set does not hold is a failed call, not a crash.
          Tool::Result.error("no tool named #{effect.name.inspect} is available")
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
