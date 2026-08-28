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

        # {Tools::Subagent::NoAskers} enrols this class for a SEAM that was
        # simply never wired to a queue -- which has nothing to do with
        # `--non-interactive`, so {REFUSAL}'s parenthetical would be a false
        # statement about that agent's own configuration there, and a human
        # chasing down an escalation that never arrived would be pointed at
        # the wrong flag. This names what is actually observable instead --
        # no mailbox this agent can reach -- and says ESCALATION rather than
        # ask, since every question a spawned child puts to `ask_human` is
        # one by construction (see {Tools::AskHuman::Parent#escalation}).
        NO_MAILBOX = "no human mailbox is reachable from this agent, so the escalation ask_human tried " \
                     "to relay has nobody to put it to and no answer will ever come back. Decide with " \
                     "what you have, or stop and say what you needed."

        # `text:` lets a caller choose WHICH observable fact this asker
        # states -- {REFUSAL} by default, since {CLI::Wiring::Askers#asker_over}
        # is the one caller for whom `--non-interactive` really is the reason.
        # NOT named `refusal:`: `spec/refusal_width_discipline_spec.rb` traces
        # dataflow into nvim's `review_refused` rail through any kwarg labeled
        # exactly that (`SLOTS`), and this refusal travels a completely
        # different wire -- a `Tool::Result.error` the MODEL reads, never an
        # `nvim_echo` a human's editor pages on -- so sharing the label would
        # subject an unrelated sentence to a bar it was never measured against.
        def initialize(text: REFUSAL, **)
          super(**)
          @text = text
        end

        protected

        # Same visibility as {AskHuman#perform}: a public override would widen
        # the tool's surface for the one arm that does the least.
        def perform(_input, _invocation) = Tool::Result.error(@text)
      end
    end
  end
end
