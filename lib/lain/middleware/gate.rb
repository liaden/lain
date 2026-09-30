# frozen_string_literal: true

module Lain
  module Middleware
    # Gates dangerous tool calls behind an approval decision before anything
    # downstream may run them. A tool-phase middleware: it passes a call on, or
    # answers it with a refusal and stops.
    #
    # What gets gated is TIER, not effect kind. The axis that predicts danger
    # is not read-versus-write, it is whether the model controls the command
    # string. A tool reports this about itself via {Tool#requires_approval?},
    # so "what needs a human" stays a property of the tool rather than a list
    # here that could drift out of sync with it. An explicit {Effect::Approval}
    # wrapper is gated regardless of the tool's own tier: wrapping is how
    # something upstream says "this one, specifically" without the gate
    # needing to know why.
    #
    # The gate holds NO Toolset of its own. It judges the tool the env
    # carries, which {Agent::ToolRunner#dispatch} resolved and hands on to the
    # interpreter only while the name still resolves to it -- so authorization
    # is decided against the object that runs, or nothing runs. That holds by
    # POSITION: the gate must be the last layer before the interpreter, because
    # a layer after it could rewrite the effect or the tool it approved.
    #
    # The approval decision is an injected policy answering
    # `#rule(effect, context)` with an {Approval::Escalation::Ruling}, never a
    # hardcoded terminal prompt: `lib/` may not touch the terminal
    # (spec/output_discipline_spec.rb), so a real interactive policy belongs to
    # the frontend and is handed in. A ruling rather than a Boolean because a
    # refusal the session decided before anyone was asked has to say so, or the
    # model takes "denied" for a missing tool and routes around it.
    #
    # Middleware is the Rack-idiom public API, so a bare `#call(effect,
    # context) -> Boolean` stays a legitimate policy too. It is adapted ONCE,
    # here at construction ({Callable}), and its rulings carry no reason.
    #
    # {ApproveAll} is an explicit, named opt-out; {DenyAll} is its Null-Object
    # opposite and the default -- safer to refuse an unattended gate than to
    # silently run it. Neither is what a mode resolves to: both approval levels
    # are an {Approval::Escalation} ladder, so a session's own triage and rule
    # denies decide under `/mode auto` too.
    class Gate < Base
      # Approves every gated call without consulting a rung: for a gate built
      # where no session rules exist to consult, never for a chat's mode.
      class ApproveAll
        RUNG = "approve_all"
        BECAUSE = "the policy approves every gated call"

        def call(_effect, _context) = true
        def rule(_effect, _context) = Approval::Escalation::Ruling.allow(rung: RUNG, because: BECAUSE)
      end

      # Correct when no interactive frontend is attached to answer for a
      # human, and the safe default.
      class DenyAll
        RUNG = "deny_all"
        BECAUSE = "the policy refuses every gated call"

        def call(_effect, _context) = false
        def rule(_effect, _context) = Approval::Escalation::Ruling.deny(rung: RUNG, because: BECAUSE)
      end

      # A bare callable policy, answering the ruling its Boolean implies and
      # nothing more: no reason, and never final.
      Callable = Data.define(:policy) do
        # The one normalisation, shared by every slot a policy is handed to:
        # a policy answering `#rule` as it is, anything else wrapped.
        def self.of(policy) = policy.respond_to?(:rule) ? policy : new(policy)

        def rule(effect, context)
          verdict = policy.call(effect, context) ? :allow : :deny
          Approval::Escalation::Ruling.public_send(verdict, rung: "callable", because: "")
        end
      end

      # What a refused call is reported as when nothing more specific was
      # wired.
      DENIAL = "approval denied for tool %<name>s"

      # What a FINAL refusal is reported as, whatever denial was injected: the
      # session's own rules refused it before anyone could be asked, so the
      # sentence has to say why and that asking again cannot help.
      FINAL = "refused tool %<name>s: %<because>s; no approval will lift this, " \
              "so do not re-send the same command in another form"

      # A tool stack this gate does not close.
      class Unclosed < Error; end

      # The check every agent's tool stack is held to before a tool runs
      # through it: the path refusal and then this gate end it. The gate last,
      # because its guarantee is positional -- a layer after it could rewrite
      # the tool or the input it approved. {Sensitivity} just ahead, because a
      # denied path is not approvable and must be refused before a human is
      # asked about it.
      #
      # @param stack [Middleware::Stack]
      # @return [Middleware::Stack] the same stack
      # @raise [Unclosed] naming the layers the stack does end in
      def self.closes!(stack)
        ending = stack.to_a.last(2)
        return stack if ending.map(&:class) == [Sensitivity, self]

        raise Unclosed, "a tool stack must end in the path refusal and then the gate, with nothing after the " \
                        "gate to rewrite what it approved; this one ends in #{ending.map(&:class).inspect}"
      end

      # @param policy [#rule, #call] the approval decision, `(effect, context)
      #   -> Ruling`, or a bare `-> Boolean` callable adapted once here; receives
      #   the inner ToolCall even when wrapped in an Approval
      # @param sensitivity [#gates?] the second gating axis, `(effect, cwd:)
      #   -> Boolean`, over the PATH a call names rather than the tool's tier.
      #   ROOT-QUALIFIED because {Middleware::Sensitivity} is a sibling under
      #   this very namespace, and a bare `Sensitivity` resolves to it.
      # @param denial [String] the sentence a refusal that is not final is
      #   reported as, with `%<name>s` standing in for the tool. Injected
      #   because the DEFAULT one is only honest when a human was actually
      #   asked and said no -- which reads to a model as a decision that could
      #   go the other way, so it tries again. A session where nobody was
      #   asked, and nobody can be, has to say so or it invites exactly that
      #   retry. That is a fact about the SESSION, not about one ruling, which
      #   is why it is injected here rather than carried on the policy's answer.
      def initialize(policy: DenyAll.new, sensitivity: ::Lain::Sensitivity::Policy::Null.instance, denial: DENIAL)
        @policy = Callable.of(policy)
        @sensitivity = sensitivity
        @denial = denial
        super()
        freeze
      end

      # Approved, the call goes downstream UNWRAPPED, so the interpreter sees
      # the tool call itself. A denial is reported, never raised, so the loop
      # continues instead of wedging on a refused call.
      #
      # The ruling is handed to a context that takes one, whichever policy
      # made it: {WithholdAutomaticOutput} scans only what ran under an
      # automatic allow, and a fixed policy that asks no ladder is one.
      def call(env, &app)
        return downstream(env, &app) unless gated?(env)

        asked = unwrapped(env.fetch(:effect))
        ruling = witnessed(@policy.rule(asked, env[:context]), env[:context])
        return downstream(env.merge(effect: asked), &app) if ruling.allow?

        env.merge(result: Tool::Result.error(refusal(ruling, asked.name.inspect)))
      end

      private

      def refusal(ruling, name)
        return format(FINAL, name:, because: ruling.told) if ruling.final?

        format(@denial, name:)
      end

      def unwrapped(effect) = effect.approval? ? effect.effect : effect

      def witnessed(ruling, context)
        context.ruled(ruling) if context.respond_to?(:ruled)
        ruling
      end

      def gated?(env)
        effect = env.fetch(:effect)
        effect.approval? || (effect.tool_call? && judged?(effect, env.fetch(:tool), env[:context]))
      end

      # Two axes, OR'd: the TIER the tool declares about itself, and the PATH
      # this particular call names. Neither can ungate the other -- a policy
      # that gates nothing leaves `bash` gated, and a tier-1 tool still reaches
      # a human for `.env`.
      #
      # Both stay behind `held?`: a name the toolset does not hold passes on to
      # the interpreter, which reports it by name, rather than being gated on a
      # path in an input nothing will read.
      def judged?(effect, tool, context)
        tool.held? &&
          (tool.requires_approval? || @sensitivity.gates?(effect, cwd: ::Lain::Session.cwd_of(context)))
      end
    end
  end
end
