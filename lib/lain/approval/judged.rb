# frozen_string_literal: true

module Lain
  module Approval
    # The judge-first rung of `auto` approval: a model {Judge} decides the
    # calls it can, and the rest go to the asking rung below it.
    #
    # Tier 0 comes first and asks no model. A call barred from automatic
    # approval, or one whose path the classifier gated for what it is (a
    # credential, a name, an operator's rule, a protected or malformed path),
    # never reaches the judge, because a model approve could not apply to it.
    #
    # Whatever this rung hands down, it first journals one `escalation` record
    # of its own saying why, so a reader can tell a call the judge deferred
    # from one it never saw or one it faulted on.
    class Judged
      NAME = "auto"
      APPROVED = "the judge approved this call"
      DENIED = "the judge refused this call"
      DEFERRED = "deferred"
      FAULT = "fault"
      UNJUDGEABLE = "unjudgeable"

      # The asking rung of a session nobody is attached to. A barred call is
      # refused finally, on {Escalation::Remainder}'s terms: no approval at this
      # level lifts it, so the model is told retrying will not help.
      class Unattended
        BECAUSE = "approval is auto and this session was started with --non-interactive, so a call the judge " \
                  "did not approve, or was not allowed to judge, has no human to ask and is refused"
        BARRED = "approval is auto, and this command is barred from automatic approval"
        TOLD = "this command's automatically approved output held a credential, so only a human may approve " \
               "it, and this session was started with --non-interactive, so no human can -- retrying will " \
               "fail the same way"

        def initialize = freeze

        def name = NAME

        def call(_effect, context)
          return Escalation::Ruling.deny(rung: NAME, because: BARRED, final: true, told: TOLD) \
            if Escalation.barred?(context)

          Escalation::Ruling.deny(rung: NAME, because: BECAUSE)
        end
      end

      # @param judge [#call] answers `:approve`, `:deny`, `:defer` or `:fault` ({Judge})
      # @param policy [Sensitivity::Policy] what decides whether a call's path may be judged
      # @param asking [#call] the rung a call goes to when the judge does not
      #   settle it: {Escalation::Surfaces}, or {Unattended}
      # @param journal [#record]
      def initialize(judge:, policy:, asking:, journal:)
        @judge = judge
        @policy = policy
        @asking = asking
        @journal = journal
        freeze
      end

      def name = NAME

      # @param effect [Effect::ToolCall]
      # @param context [Object, nil] as {Middleware::Gate} threads it through
      # @return [Escalation::Ruling]
      def call(effect, context)
        return handed_down(effect, context, abstain(UNJUDGEABLE)) unless judgeable?(effect, context)

        cause = nil
        verdict = @judge.call(requester: Queue.requester_for(context), tool: effect.name, input: effect.input) do |why|
          cause = why
        end
        ruled(verdict, effect, context, cause)
      end

      private

      def ruled(verdict, effect, context, cause)
        case verdict
        when :approve then Escalation::Ruling.allow(rung: NAME, because: APPROVED)
        when :deny then Escalation::Ruling.deny(rung: NAME, because: DENIED)
        when :defer then handed_down(effect, context, abstain(DEFERRED))
        else faulted(effect, context, cause)
        end
      end

      # Marked faulted so the ladder suppresses an automatic allow from below,
      # as it would had the judge been a rung of its own.
      def faulted(effect, context, cause)
        handed_down(effect, context, Escalation::Ruling.fault(rung: NAME, because: FAULT), error: cause)
          .with(fault: true)
      end

      def abstain(reason) = Escalation::Ruling.abstain(rung: NAME, because: reason)

      def judgeable?(effect, context)
        return false if Escalation.barred?(context)

        path = ::Lain::Sensitivity::Policy.path_in(effect)
        path.nil? || verdict_on(path, context).oracle_approvable?
      end

      def verdict_on(path, context)
        @policy.judge(path, cwd: ::Lain::Session.cwd_of(context), within: ::Lain::Sensitivity::Policy.base_of(context))
      end

      def handed_down(effect, context, why, error: nil)
        record(why, effect, error)
        @asking.call(effect, context)
      end

      # Evidence about a call must never cost the call.
      def record(ruling, effect, error)
        @journal.record({ "type" => Escalation::TYPE, "tool" => effect.name, "tool_use_id" => effect.tool_use_id,
                          "error" => error }.compact.merge(ruling.record))
      rescue StandardError
        nil
      end
    end
  end
end
