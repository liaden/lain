# frozen_string_literal: true

module Lain
  module Effect
    class Handler
      # Gates dangerous tool calls behind an approval decision before an inner
      # handler may perform them. Composes by decoration in front of {Live}.
      #
      # What gets gated is TIER, not effect kind. The axis that predicts danger
      # is not read-versus-write, it is whether the model controls the command
      # string (see the plan's "Tool tiers, and where the security boundary is").
      # A tool reports this about itself via {Tool#requires_approval?}, so "what
      # needs a human" stays a property of the tool rather than a list here that
      # could drift out of sync with it. An explicit {Effect::Approval} wrapper
      # is gated regardless of the tool's own tier: wrapping is how something
      # upstream says "this one, specifically" without Gate needing to know why.
      #
      # Gate holds NO Toolset of its own -- it reads the tier off whatever
      # `inner` resolves the name to ({Handler#tool_named}), for the
      # "capabilities, not permissions" reason that method documents.
      #
      # The approval decision is an injected policy answering
      # `#call(effect, context) -> Boolean`, never a hardcoded terminal prompt:
      # `lib/` may not touch the terminal (spec/output_discipline_spec.rb), so a
      # real interactive policy belongs to Frontend::TTY and is handed in.
      # {ApproveAll} is what the `auto` posture resolves to; {DenyAll} is its
      # Null-Object opposite and the default -- safer to refuse an unattended
      # gate than to silently run it.
      class Gate < Handler
        # What {Mode::Posture}'s `auto` rung selects: an explicit, named opt-out
        # rather than a magic nil policy.
        class ApproveAll
          def call(_effect, _context) = true
        end

        # Correct when no interactive frontend is attached to answer for a
        # human, and the safe default.
        class DenyAll
          def call(_effect, _context) = false
        end

        # What a refused call is reported as when nothing more specific was
        # wired.
        DENIAL = "approval denied for tool %<name>s"

        # @param policy [#call] `(effect, context) -> Boolean`, the approval
        #   decision; receives the inner ToolCall even when wrapped in an Approval
        # @param inner [Lain::Effect::Handler, nil] performs the effect once
        #   approved, and the single source of truth for what a name resolves to
        # @param sensitivity [#gates?] the second gating axis, `(effect) ->
        #   Boolean`, over the PATH a call names rather than the tool's tier.
        #   Resolved in the default expression rather than held in a constant
        #   here: `lain.rb` loads `lain/effect` seven entries BEFORE
        #   `lain/sensitivity`, so a constant in this class body is a hard
        #   NameError at load.
        #
        #   ROOT-QUALIFIED, and it has to be: {Effect::Handler::Sensitivity} is
        #   a sibling under this very namespace, so a bare `Sensitivity`
        #   resolves through `Module.nesting` to the HANDLER and this expression
        #   dies on `Handler::Sensitivity::Policy`. It failed only when a caller
        #   omitted the keyword, which is most of them.
        #
        # @param denial [String] the sentence a refused call is reported as,
        #   with `%<name>s` standing in for the tool. Injected because the
        #   DEFAULT one is only honest when a human was actually asked and said
        #   no -- which reads to a model as a decision that could go the other
        #   way, so it tries again. A session where nobody was asked, and nobody
        #   can be, has to say so or it invites exactly that retry. The reason
        #   cannot travel on the policy: that duck answers a Boolean, and a
        #   Boolean has no room for a why.
        def initialize(policy: DenyAll.new, inner: nil, sensitivity: Lain::Sensitivity::Policy::Null.instance,
                       denial: DENIAL)
          super(inner:)
          @policy = policy
          @sensitivity = sensitivity
          @denial = denial
        end

        def handles?(effect) = effect.approval? || gated_tool_call?(effect)

        protected

        def perform(effect, context)
          inner_effect = effect.approval? ? effect.effect : effect
          return run(inner_effect, context) if @policy.call(inner_effect, context)

          # A denial is reported, never raised, so the loop continues instead of
          # wedging on a refused call -- correctness gate 3's analog.
          Tool::Result.error(format(@denial, name: inner_effect.name.inspect))
        end

        private

        def run(effect, context)
          raise UnhandledEffect, "#{self.class} approved an effect with no inner handler to run it" unless @inner

          @inner.call(effect, context)
        end

        def gated_tool_call?(effect)
          return false unless effect.tool_call?

          # Two axes, OR'd: the TIER the tool declares about itself, and the
          # PATH this particular call names. Neither can ungate the other -- a
          # policy that gates nothing leaves `bash` gated, and a tier-1 tool
          # still reaches a human for `.env`.
          #
          # Both stay BEHIND the nil check: a name inner does not hold falls
          # through to inner, which reports the usual unknown-tool error, rather
          # than being gated on a path in an input nothing will read.
          tool = tool_named(effect.name)
          !tool.nil? && (tool.requires_approval? || @sensitivity.gates?(effect))
        end
      end
    end
  end
end
