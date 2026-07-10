# frozen_string_literal: true

require_relative "../effect"
require_relative "../handler"
require_relative "../tool"

module Lain
  class Handler
    # Gates dangerous tool calls behind an approval decision before an inner
    # handler is allowed to actually perform them. Composes by decoration in
    # front of {Live}, the same chain-of-responsibility shape every Handler
    # uses: Approving intercepts what it cares about and lets everything else
    # fall through to `inner` untouched (see {Handler#call}).
    #
    # What gets gated is TIER, not effect kind. The axis that predicts danger is
    # not read-versus-write, it is whether the model controls the command
    # string (see the plan's "Tool tiers, and where the security boundary is").
    # A tool reports this about itself via {Tool#requires_approval?}, so "what
    # needs a human" stays a property of the tool -- not a list maintained here
    # that could drift out of sync with the tool it describes. An explicit
    # {Effect::Approval} wrapper is gated regardless of the tool's own tier:
    # wrapping is how something upstream says "this one, specifically" without
    # Approving needing to know why.
    #
    # Approving holds NO Toolset of its own. It asks its `inner` handler what a
    # name resolves to ({Handler#tool_named}), so the tier it gates on is read
    # from the exact tool the executor will dispatch. A second Toolset reference
    # here could diverge from the executor's, and then the gate would consult
    # one map while dispatch used another -- authorization decided against a
    # different set than possession, the very failure "tools are capabilities,
    # not permissions" exists to prevent. One map, by construction.
    #
    # The approval decision is an injected policy -- anything answering
    # `#call(effect, context) -> Boolean` -- never a hardcoded terminal prompt.
    # `lib/` may not touch the terminal (see spec/output_discipline_spec.rb); a
    # real interactive policy belongs to Frontend::TTY and is handed in from
    # there. {ApproveAll} is the `--yolo` opt-out; {DenyAll} is its Null-Object
    # opposite and the default -- safer to refuse an unattended gate than to
    # silently run it.
    class Approving < Handler
      # Approves every gated call without asking. The `--yolo` path: an
      # explicit, named opt-out rather than a magic nil policy.
      class ApproveAll
        def call(_effect, _context) = true
      end

      # Denies every gated call. Correct when no interactive frontend is
      # attached to answer for a human, and the safe default.
      class DenyAll
        def call(_effect, _context) = false
      end

      # @param policy [#call] `(effect, context) -> Boolean`, the approval
      #   decision; receives the inner ToolCall even when wrapped in an Approval
      # @param inner [Lain::Handler, nil] performs the effect once approved, and
      #   the single source of truth for what a tool name resolves to
      def initialize(policy: DenyAll.new, inner: nil)
        super(inner: inner)
        @policy = policy
      end

      def handles?(effect)
        effect.is_a?(Effect::Approval) || gated_tool_call?(effect)
      end

      protected

      def perform(effect, context)
        inner_effect = effect.is_a?(Effect::Approval) ? effect.effect : effect
        return run(inner_effect, context) if @policy.call(inner_effect, context)

        # Correctness gate 3's analog for approval: a denial is reported, never
        # raised, so the loop continues instead of wedging on a refused call.
        Tool::Result.error("approval denied for tool #{inner_effect.name.inspect}")
      end

      private

      def run(effect, context)
        raise UnhandledEffect, "#{self.class} approved an effect with no inner handler to run it" unless @inner

        @inner.call(effect, context)
      end

      def gated_tool_call?(effect)
        return false unless effect.is_a?(Effect::ToolCall)

        # Ask inner what this name resolves to, so the tier is read off the tool
        # the executor will dispatch. A name inner does not hold (nil) is not
        # this handler's problem to report: it falls through to inner, which
        # raises the usual unknown-tool error the way any declined effect does.
        tool = tool_named(effect.name)
        !tool.nil? && tool.requires_approval?
      end
    end
  end
end
