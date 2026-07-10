# frozen_string_literal: true

require_relative "../effect"
require_relative "../tool"
require_relative "../toolset"

module Lain
  class Handler
    # Interprets effects by actually doing them: dispatches a {Effect::ToolCall}
    # to the tool the {Lain::Toolset} holds under that name and runs it.
    #
    # This is where correctness gate 3 is enforced. A tool that raises -- whether
    # from a bug, a bad input, or a violated contract -- must never propagate past
    # the loop, so every dispatch is wrapped: any `StandardError` becomes a
    # {Tool::Result} with `is_error: true`. The raising happens honestly inside
    # the tool (contracts stay Eiffel-strict); the *conversion* to a loop-safe
    # error result happens here, once, at the boundary the loop trusts.
    #
    # Live is the executor of last resort. It does not itself gate on approval; a
    # deployment composes an approving handler in front of it. So when an
    # {Effect::Approval} reaches Live, Live treats it as already-approved and
    # runs the inner effect -- otherwise a stack with no approver would wedge on
    # every gated call.
    class Live < Handler
      # @param toolset [Lain::Toolset] the capabilities this handler can dispatch
      # @param inner [Lain::Handler, nil] fallback for other effect kinds
      def initialize(toolset:, inner: nil)
        super(inner: inner)
        @toolset = toolset
      end

      def handles?(effect)
        effect.is_a?(Effect::ToolCall) || effect.is_a?(Effect::Approval)
      end

      protected

      def perform(effect, context)
        case effect
        when Effect::Approval then call(effect.effect, context)
        when Effect::ToolCall then dispatch(effect, context)
        else raise UnhandledEffect, "#{self.class} cannot perform #{effect.class}"
        end
      end

      private

      def dispatch(effect, context)
        @toolset.fetch(effect.name).call(effect.input, context)
      rescue Toolset::UnknownTool
        # The model asked for a tool this set does not hold. That is a failed
        # call, not a crash: report it back as an error result and let the loop
        # continue.
        Tool::Result.error("no tool named #{effect.name.inspect} is available")
      rescue StandardError => e
        # Correctness gate 3: a failing tool returns a tool_result with
        # is_error: true; it is never dropped and never raised past the loop.
        Tool::Result.error("#{e.class}: #{e.message}")
      end
    end
  end
end
