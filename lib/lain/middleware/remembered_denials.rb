# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Lain
  module Middleware
    # Refuses a call on a path a human already denied the same requester, or on
    # anything under it, or an exact repeat of a call they denied, rather than
    # parking it to ask again. The memory is the queue's own
    # ({Approval::Queue#denied} and {Approval::Queue#denied_call}), so a run
    # with no queue remembers nothing.
    #
    # Only a call the gate would have asked about is refused here: a deny on
    # an ancestor of the project must not stop the project's own reads, which
    # never reach a human at all. It sits ahead of {Sensitivity} rather than
    # being a rung of the ladder for the same reason, since an ordinary read
    # never reaches the ladder and a rung could not tell it apart from one
    # under the denied path.
    #
    # The refusal is the gate's non-final one, in the human's words: the human
    # could still change their mind, and the model should hear the same answer
    # it got the first time.
    class RememberedDenials < Base
      # A run nobody attends: nothing was denied, so nothing is remembered.
      module Unattended
        def self.denied(**) = nil
        def self.denied_call(**) = nil
      end

      # The rung a refusal from memory is journaled under, beside the ladder's
      # own, so the bench can count the asks it saved.
      RUNG = "remembered"

      PATH_DENIED = "a human denied this path earlier"
      CALL_DENIED = "a human denied this call earlier"
      private_constant :PATH_DENIED, :CALL_DENIED

      # @param queue [#denied, #denied_call] the run's approval queue, or {Unattended}
      # @param sensitivity [#gates?, #denial, #judge, #home] the same path policy
      #   the gate asks
      # @param denial [String] the gate's refusal, `%<name>s` standing for the tool
      # @param journal [#<<] where each refusal lands as an `escalation` record
      # @param requester [String, nil] who a child's stack asks for; nil reads
      #   it off the context, as the queue does
      def initialize(queue:, sensitivity:, denial:, journal: Channel::Null.instance, requester: nil)
        @queue = queue
        @sensitivity = sensitivity
        @denial = denial
        @journal = journal
        @requester = requester
        super()
        freeze
      end

      def call(env, &app)
        effect = ::Lain::Sensitivity::Policy.unwrapped(env.fetch(:effect))
        reason, because = effect.tool_call? && remembered(effect, env[:context])
        return downstream(env, &app) unless reason

        record(effect, reason, because, requester_of(env[:context]))
        said = reason.presence || "#{because} this session"
        env.merge(result: Tool::Result.error("#{format(@denial, name: effect.name.inspect)}: #{said}"))
      end

      private

      def remembered(effect, context)
        cwd = Session.cwd_of(context)
        on_path = remembered_on_path(effect, context, cwd)
        return [on_path, PATH_DENIED] if on_path
        return unless @sensitivity.denial(effect, cwd:).nil?

        repeated = @queue.denied_call(requester: requester_of(context), tool: effect.name, input: effect.input, cwd:)
        [repeated, CALL_DENIED] if repeated
      end

      def remembered_on_path(effect, context, cwd)
        if effect.name == Approval::Queue::BASH
          remembered_in_command(effect, context, cwd)
        else
          remembered_at(effect, context, cwd)
        end
      end

      # A path the session refuses outright passes on to {Sensitivity}, whose
      # final refusal says no approval can lift it, which a remembered no cannot.
      def remembered_at(effect, context, cwd)
        path = ::Lain::Sensitivity::Policy.path_in(effect)
        resolved = path && Approval::Queue.resolved(path, cwd, home: @sensitivity.home)
        reason = resolved && denied_at(resolved, context)
        reason if reason && asked?(effect, context, cwd)
      end

      # Each named path is held as a call on that path would be, so a command
      # is refused only on a path a read of it would have parked.
      def remembered_in_command(effect, context, cwd)
        within = ::Lain::Sensitivity::Policy.base_of(context)
        named = Approval::Queue.named(effect.input, cwd:, home: @sensitivity.home).paths
        named.lazy.map { [_1, denied_at(_1.resolved, context)] }
             .find { |path, reason| reason && asked_at?(path, cwd, within) }&.last
      end

      def denied_at(path, context) = @queue.denied(requester: requester_of(context), path:)

      def asked?(effect, context, cwd)
        @sensitivity.denial(effect, cwd:).nil? &&
          @sensitivity.gates?(effect, cwd:, within: ::Lain::Sensitivity::Policy.base_of(context))
      end

      # A protected name spelled bare is only flagged by the triage, so the
      # call parks; written as a path it is refused outright, and a remembered
      # no must not stand in for that final refusal.
      def asked_at?(path, cwd, within)
        verdict = @sensitivity.judge(path.resolved, cwd:, within:)
        !verdict.ordinary? && (!verdict.denied? || !path.word.match?(Approval::Escalation::Triage::PATHLIKE))
      end

      def record(effect, reason, because, requester)
        ruling = Approval::Escalation::Ruling.deny(rung: RUNG, because:, authority: :human, said: reason)
        Telemetry::Escalation.write(@journal, ruling, effect, nil, requester:)
      end

      def requester_of(context) = Telemetry::Escalation.requester_of(context, @requester)
    end
  end
end
