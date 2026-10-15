# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Lain
  module Middleware
    # Refuses a call on a path a human already denied the same requester, or on
    # anything under it, rather than parking it to ask again. The memory is the
    # queue's own ({Approval::Queue#denied}), so a run with no queue remembers
    # nothing.
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
      end

      # The rung a refusal from memory is journaled under, beside the ladder's
      # own, so the bench can count the asks it saved.
      RUNG = "remembered"

      # @param queue [#denied] the run's approval queue, or {Unattended}
      # @param sensitivity [#gates?, #denial] the same path policy the gate asks
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
        reason = effect.tool_call? && remembered(effect, env[:context])
        return downstream(env, &app) unless reason

        record(effect, reason, requester_of(env[:context]))
        env.merge(result: Tool::Result.error([format(@denial, name: effect.name.inspect), reason.presence]
                                               .compact.join(": ")))
      end

      private

      # A path the session refuses outright passes on to {Sensitivity}, whose
      # final refusal says no approval can lift it, which a remembered no cannot.
      def remembered(effect, context)
        cwd = Session.cwd_of(context)
        path = ::Lain::Sensitivity::Policy.path_in(effect)
        resolved = path && Approval::Queue.resolved(path, cwd)
        reason = resolved && @queue.denied(requester: requester_of(context), path: resolved)
        reason if reason && asked?(effect, context, cwd)
      end

      def asked?(effect, context, cwd)
        @sensitivity.denial(effect, cwd:).nil? &&
          @sensitivity.gates?(effect, cwd:, within: ::Lain::Sensitivity::Policy.base_of(context))
      end

      def record(effect, reason, requester)
        ruling = Approval::Escalation::Ruling.deny(rung: RUNG, because: "a human denied this path earlier",
                                                   authority: :human, said: reason)
        @journal << { "type" => Approval::Escalation::TYPE, "tool" => effect.name,
                      "tool_use_id" => effect.tool_use_id, "requester" => requester }.merge(ruling.record)
      end

      def requester_of(context) = @requester || Approval::Queue.requester_for(context, Approval::Queue::REQUESTER)
    end
  end
end
