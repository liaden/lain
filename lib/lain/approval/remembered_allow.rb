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
    #
    # A human's secrets answer is replayed for another call of the same
    # requester too, but only a pure read: every stage a known reader with
    # flags that keep it to its own operands, so nothing is written, deleted,
    # run or sent, and every file read whole and released with the same
    # bytes. It runs as a plain allow, so the ladder
    # contains it with the project's masks standing. Any other call over the
    # same files goes down the ladder as it would have.
    class RememberedAllow
      REMEMBERED = "a human approved this exact call earlier this session"
      RELEASED = "a human released these files' secrets earlier this session, and they are unchanged"
      # Each reads only what it is named and writes nothing, with the flags the composed reader rule admits.
      READERS = %w[cat head tail wc nl grep sort cut tr rev sed].freeze

      # A session with no queue has no human whose answer could be replayed.
      module None
        def self.call(_effect, _context) = nil
      end

      # @param queue [Parked::Queue] the session's one queue, which holds the human's answers
      # @param ledger [Sensitivity::Ledger] the run's one ledger, which a human's file releases are kept in
      def initialize(queue:, ledger:)
        @queue = queue
        @ledger = ledger
        freeze
      end

      # @param effect [Effect::ToolCall]
      # @param context [Object, nil] as {Middleware::Gate} threads it through
      # @return [Escalation::Ruling, nil] the human's allow, or nil when none stands for this call
      def call(effect, context)
        return if Escalation.barred?(context)

        exact(effect, context) || released(effect, context)
      end

      private

      def exact(effect, context)
        remembered = @queue.allowed_call(requester: Parked::Queue.identity_for(context).name, tool: effect.name,
                                         input: effect.input, cwd: ::Lain::Session.cwd_of(context))
        return unless remembered && shown?(remembered, context)

        Escalation::Ruling.allow(rung: Judged::NAME, because: REMEMBERED, authority: :human,
                                 contained: remembered.contained)
      end

      # Recording is idempotent, so the queue's answers are read in whole on each ask rather than tracked.
      def released(effect, context)
        return unless pure_read?(effect, context)

        requester = Parked::Queue.identity_for(context).name
        @queue.released_files(requester:).each { @ledger.release_files(_1, authority: :human, requester:) }
        Escalation::Ruling.allow(rung: Judged::NAME, because: RELEASED, authority: :human) \
          if @ledger.released_files?(Disclosure.in(context).whole_files, requester:)
      end

      # Read as a shell would only where {Shell::Reading} is certain, which refuses every redirect that writes.
      def pure_read?(effect, context)
        command = ::Lain::Shell::Named.field_of(effect.input, ::Lain::Shell::Named::COMMAND)
        return false unless effect.name == Parked::Queue::BASH && command.is_a?(String)

        parse = ::Lain::Middleware::ParsedCommand.carried(command, context) || ::Lain::Shell::Parse.new.call(command)
        term, = ::Lain::Shell::Reading.from(parse, ::Lain::Session.cwd_of(context))
        !term.nil? && term.stages.all? { reader?(_1.argv) }
      end

      def reader?(argv)
        program, *arguments = argv
        READERS.include?(program) && ComposedTerm::PROGRAMS.fetch(program).admits?(arguments)
      end

      def shown?(remembered, context) = (Parked::Queue.secrets_of(Disclosure.in(context)) - remembered.secrets).empty?
    end
  end
end
