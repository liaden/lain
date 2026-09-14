# frozen_string_literal: true

require "state_machines"

module Lain
  class Agent
    # The loop's states and its legal moves, declared once and mixed into the
    # {Agent}. The diagram in docs/agent-state-machine.md is generated from this
    # declaration, and a spec fails the build when the two drift.
    #
    # Two invariants ride on this being a real machine and not a bag of
    # `@state =` assignments. An undeclared move RAISES, where `@state =
    # :nonsense` sailed through. And the wire-facing events are named for the
    # normalized {StopReason} vocabulary itself, so {Agent#transition} fires the
    # reason directly (`send("#{stop_reason}!")`) with no `case` to re-parse it
    # -- safe because `StopReason.normalize` closes the wire's open enum to a
    # fixed set before the machine sees it, and a totality spec pins one
    # declared event per member, so adding a StopReason without an event fails a
    # test rather than a run.
    #
    # `:awaiting_approval` has no incoming event yet; it is where
    # `Middleware::Gate` will land, declared now so the state set is
    # complete and the generated diagram is honest about it.
    #
    # Why `state_machines` and not ActiveModel validations: validations gate
    # *attribute values*, not *transitions between them*, which is the whole
    # invariant here. State values are Symbols (`value:`), not the gem's default
    # Strings, because `Agent#state` is public surface and callers compare
    # against `:done`.
    module LoopMachine
      # A constant, not a block inside the `included` hook, so the event and
      # state lines do not count toward that method's length.
      DEFINITION = proc do
        # The observability seam: the Agent's injected listener, Null by
        # default, sees every transition before it takes effect.
        before_transition { |agent, transition| agent.__send__(:announce_transition, transition) }

        # Structural moves, no wire meaning.
        event(:dispatch) { transition %i[awaiting_user awaiting_model awaiting_tools] => :awaiting_model }
        event(:reopen) { transition any => :awaiting_user }

        # One event per normalized StopReason -- fired by name from Agent#transition.
        event(:tool_use) { transition awaiting_model: :awaiting_tools }
        event(:pause_turn) { transition awaiting_model: :awaiting_model }
        event(:end_turn) { transition awaiting_model: :done }
        event(:stop_sequence) { transition awaiting_model: :done }
        event(:max_tokens) { transition awaiting_model: :failed }
        event(:refusal) { transition awaiting_model: :failed }
        event(:unknown) { transition awaiting_model: :failed }

        # The dual-ledger outer loop's stall->replan pair, purely ADDITIVE: both
        # move to or from the new `:stalled` state, so no previously legal move
        # becomes illegal and neither lands in `:failed`, leaving the
        # FAILURE_REASONS totality untouched. Wired for {Arm::DualLedger}'s
        # {Planner}; the {Agent}'s own machine never fires them.
        event(:stall) { transition awaiting_model: :stalled }
        event(:replan) { transition stalled: :awaiting_model }

        state :awaiting_user, value: :awaiting_user
        state :awaiting_model, value: :awaiting_model
        state :awaiting_tools, value: :awaiting_tools
        state :awaiting_approval, value: :awaiting_approval
        state :stalled, value: :stalled
        state :done, value: :done
        state :failed, value: :failed
      end

      # STATES is derived from the machine so the constant cannot drift from the
      # declaration.
      def self.included(base)
        base.state_machine(:state, initial: :awaiting_user, &DEFINITION)
        base.const_set(:STATES, base.state_machine(:state).states.map(&:name).freeze)
      end

      private

      # Private; the machine's `before_transition` reaches it via `__send__`.
      def announce_transition(transition)
        @transition_listener.on_transition(
          from: transition.from, to: transition.to, event: transition.event
        )
      end
    end
  end
end
