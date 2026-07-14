# frozen_string_literal: true

require "state_machines"

module Lain
  class Agent
    # The loop's states and its legal moves, declared once and mixed into the
    # {Agent}. Extracted from the Agent so the machine is a named, separately
    # readable unit rather than fifteen lines wedged into an already-large class.
    #
    # Two invariants ride on this being a real machine and not a bag of `@state =`
    # assignments. First, an undeclared move RAISES: `dispatch!` from `:done` is a
    # `StateMachines::InvalidTransition`, where the old `@state = :nonsense` would
    # have sailed through. Second, the wire-facing events are named for the
    # normalized {StopReason} vocabulary itself, so {Agent#transition} fires the
    # reason directly (`send("#{stop_reason}!")`) with no `case` to re-parse it
    # (gate 6 totality). That coupling is deliberate: `StopReason.normalize`
    # closes the wire's open enum to a fixed set before the machine sees it, and a
    # totality spec pins one declared event per member -- adding a StopReason
    # without an event fails a test, not a run.
    #
    # `dispatch` and `reopen` are the structural moves that carry no wire meaning;
    # the rest map one StopReason each. `:awaiting_approval` has no incoming event
    # yet; it is where `Effect::Handler::Gate` will land, and it is declared now so
    # the state set is complete and the generated diagram is honest about it.
    #
    # Why `state_machines` and not "ActiveModel with validations": there is no
    # `ActiveModel::StateMachine` -- validations gate *attribute values*, not
    # *transitions between them*, which is the whole invariant here (an illegal
    # move must raise). `state_machines` is the maintained successor to the
    # `state_machine` gem and models exactly that. And the extraction into a mixin
    # is genuine, not just line-count relief: the machine is a self-contained unit
    # with its own spec and a generated diagram (`agent_state_machine_diagram_spec`)
    # -- naming it `LoopMachine` says what it is where the Agent only `include`s it.
    #
    # State values are Symbols (`value:`), not the gem's default Strings, because
    # `Agent#state` is public surface and callers compare against `:done`.
    module LoopMachine
      # Held as a proc so the DSL block lives in a constant, not inside the
      # `included` hook -- otherwise every event and state line would count toward
      # that method's length.
      DEFINITION = proc do
        # The observability seam. Fires before every transition takes effect; the
        # Agent's injected listener (defaulting to a Null object) receives it.
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

        state :awaiting_user, value: :awaiting_user
        state :awaiting_model, value: :awaiting_model
        state :awaiting_tools, value: :awaiting_tools
        state :awaiting_approval, value: :awaiting_approval
        state :done, value: :done
        state :failed, value: :failed
      end

      # STATES is derived from the machine so the constant cannot drift from the
      # declaration. `contain_exactly` in the spec means order is irrelevant.
      def self.included(base)
        base.state_machine(:state, initial: :awaiting_user, &DEFINITION)
        base.const_set(:STATES, base.state_machine(:state).states.map(&:name).freeze)
      end

      private

      # Announce a transition to the injected listener before it takes effect.
      # Kept private; the machine's `before_transition` reaches it via `__send__`.
      def announce_transition(transition)
        @transition_listener.on_transition(
          from: transition.from, to: transition.to, event: transition.event
        )
      end
    end
  end
end
