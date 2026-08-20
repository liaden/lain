# frozen_string_literal: true

module Lain
  module Tools
    class AskHuman
      # The asker a run wires when nobody is at the terminal
      # (`lain chat --non-interactive`). It refuses the call and writes
      # NOTHING: no Q event, no arrival, no promise -- because each of those is
      # half of an exchange whose other half can never come, and a Q left
      # unconsumed in the record is a question the session is still shown to be
      # waiting on.
      #
      # A REFUSAL, not an absent tool. Attenuating `ask_human` out of the set
      # would leave the model to guess in silence and to read the gap as a
      # harness that does not have the capability at all; a {Tool::Result} says
      # what happened, in the tool's own name, and is the one thing a model can
      # act on. The instruction to decide or to stop is the actionable half --
      # a refusal that only says "no" invites the same call again.
      #
      # Which asker a run gets is {CLI::Wiring::Askers}' decision, made once at
      # enrolment, so the parent chat and every child it spawns refuse
      # together: a subagent's question is as unanswerable as its parent's when
      # the terminal is empty.
      class Unattended < AskHuman
        REFUSAL = "no human is attached to this session (it was started with --non-interactive), so " \
                  "ask_human has nobody to put this to and no answer will ever come back. Decide with " \
                  "what you have, or stop and say what you needed."

        protected

        # Same visibility as {AskHuman#perform}, which the dispatch path calls
        # on itself: a public override here would widen the tool's surface for
        # the one arm that does the least.
        def perform(_input, _invocation) = Tool::Result.error(REFUSAL)
      end
    end
  end
end
