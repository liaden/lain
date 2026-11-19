# frozen_string_literal: true

module Lain
  module Approval
    # A human's plain allow of an exact call, replayed for its repeat under
    # `auto` so the judge does not send one call to the human twice.
    #
    # {Judged} asks it for a call the judge weighs, and for one it could not
    # weigh only for its size or kind (the object store, a write below the
    # checkout's top, too many matches), whose exact text is still the exact
    # call. Either way it asks only once the resolved-program bar has passed,
    # so a program rewritten since the human's answer goes back to them, and
    # only when no path the call names is a protected target, which is never
    # automatic. A walk or glob that reaches a protected file without naming it
    # still replays, since the human's yes covered that exact secret-bearing
    # walk, which ran contained when confinement is on, and the replay runs the
    # same way under the session's masks. An opaque command can mean another
    # call on each run, so it never replays.
    #
    # The context bar is checked here rather than left to {Escalation}, which
    # lets a human's allow through it, and a call that now reads a secret the
    # human's yes was not shown is asked again. The replay is the human's,
    # contained as their answer ran, so the sandbox treats it as the first.
    class RememberedAllow
      REMEMBERED = "a human approved this exact call earlier this session"

      # A session with no queue has no human whose answer could be replayed.
      module None
        def self.call(_effect, _context) = nil
      end

      # @param queue [Parked::Queue] the session's one queue, which holds the human's answers
      def initialize(queue:)
        @queue = queue
        freeze
      end

      # @param effect [Effect::ToolCall]
      # @param context [Object, nil] as {Middleware::Gate} threads it through
      # @return [Escalation::Ruling, nil] the human's allow, or nil when none stands for this call
      def call(effect, context)
        return if Escalation.barred?(context)

        remembered = @queue.allowed_call(requester: Parked::Queue.identity_for(context).name, tool: effect.name,
                                         input: effect.input, cwd: ::Lain::Session.cwd_of(context))
        return unless remembered && shown?(remembered, context)

        Escalation::Ruling.allow(rung: Judged::NAME, because: REMEMBERED, authority: :human,
                                 contained: remembered.contained)
      end

      private

      def shown?(remembered, context) = (Parked::Queue.secrets_of(Disclosure.in(context)) - remembered.secrets).empty?
    end
  end
end
