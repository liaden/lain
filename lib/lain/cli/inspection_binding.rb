# frozen_string_literal: true

module Lain
  module CLI
    # The read-mostly view of a live conversation that `/ruby` inspects
    # through. It hands out a Ruby {Binding} whose `self` is this object, so an
    # inspected expression resolves `timeline`/`session`/`supervisor`/`status`
    # and nothing wider -- an unqualified `agent` is a NameError, by design,
    # because the binding is a window, not the whole run.
    #
    # Frozen, so "read-mostly" is mechanical rather than a convention: a console
    # line that tries to reassign an ivar (`@timeline = ...`) raises FrozenError
    # instead of quietly rebinding what the next inspection reads. The
    # collaborators' own methods stay callable -- this scopes the surface, it
    # does not sandbox the objects.
    class InspectionBinding
      # The timeline and session come off the live Agent, so each `/ruby` reads
      # the head as it stands now rather than a snapshot frozen at wiring time.
      def self.for(env)
        new(timeline: env.timeline, session: env.agent.session,
            supervisor: env.supervisor, status: env.status)
      end

      def initialize(timeline:, session:, supervisor:, status:)
        @timeline = timeline
        @session = session
        @supervisor = supervisor
        @status = status
        freeze
      end

      attr_reader :timeline, :session, :supervisor, :status

      # Named `context`, not `binding`: a reader called `binding` would shadow
      # `Kernel#binding` inside the very eval this hands out. A fresh Binding
      # per call, so the console and an inline eval each get their own.
      def context = binding
    end
  end
end
