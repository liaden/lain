# frozen_string_literal: true

module Lain
  module Tools
    class AskHuman
      # The asker a run wires when nobody is at the terminal. It refuses and
      # writes NOTHING -- no Q event, no arrival, no promise -- because each is
      # half of an exchange whose other half can never come, and a Q left
      # unconsumed reads as a question the session is still waiting on.
      #
      # A REFUSAL, not an absent tool: attenuating `ask_human` out of the set
      # would leave the model to read the gap as a harness without the
      # capability at all. The instruction to decide or to stop is the
      # actionable half -- a refusal that only says "no" invites the same call
      # again.
      #
      # Which asker a run gets is decided once at enrolment, so the parent chat
      # and every child it spawns refuse together.
      class Unattended < AskHuman
        REFUSAL = "no human is attached to this session (it was started with --non-interactive), so " \
                  "ask_human has nobody to put this to and no answer will ever come back. Decide with " \
                  "what you have, or stop and say what you needed."

        protected

        # Same visibility as {AskHuman#perform}: a public override would widen
        # the tool's surface for the one arm that does the least.
        def perform(_input, _invocation) = Tool::Result.error(REFUSAL)
      end
    end
  end
end
