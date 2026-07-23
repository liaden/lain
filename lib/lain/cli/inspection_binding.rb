# frozen_string_literal: true

module Lain
  module CLI
    # The read-mostly view of a live conversation that `/ruby` (T22) inspects
    # through. It exposes exactly the collaborators the card names -- the
    # timeline, the session, the fleet supervisor, and the status feed -- as
    # reader messages, and hands out a Ruby {Binding} whose `self` is this
    # object, so an inspected expression resolves `timeline`/`session`/
    # `supervisor`/`status` and nothing wider (an unqualified `agent` is a
    # NameError, by design -- the binding is a window, not the whole run).
    #
    # Frozen, so "read-mostly" is mechanical rather than a convention: a console
    # line that tries to reassign an ivar (`@timeline = ...`) raises FrozenError
    # instead of quietly rebinding what the next inspection reads. The
    # collaborators' own methods stay callable -- this scopes the surface, it
    # does not sandbox the objects.
    class InspectionBinding
      # Built where a command runs -- the timeline and session come off the live
      # Agent (so each `/ruby` reads the head as it stands now, not a snapshot
      # frozen at wiring time), the supervisor and status straight off the
      # frozen {Command::Env}.
      def self.for(env)
        new(timeline: env.agent.timeline, session: env.agent.session,
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

      # Named `context`, not `binding`: `Kernel#binding` is what produces it, and
      # a reader called `binding` would shadow that inside the very eval this
      # hands out. A fresh Binding per call is deliberate -- the console and an
      # inline eval each get their own, and there is no per-instance state to
      # memoize on a frozen object anyway.
      def context = binding
    end
  end
end
