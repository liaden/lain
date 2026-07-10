# frozen_string_literal: true

module Lain
  class Agent
    # The seam observability hangs from. Every state change the Agent makes is
    # announced here as `(from:, to:, event:)` before it takes effect, so the
    # Journal (M2) can subscribe without the Agent knowing anything listens.
    #
    # This is the reason `state_machines` was chosen over a hand-rolled `@state`:
    # a declared machine gives the transition a single, interceptable moment. A
    # scattered `@state = :x` has no such hook.
    module TransitionListener
      # Null object. Satisfies the same duck as a real listener and sends every
      # transition nowhere, so an Agent built without one behaves exactly as one
      # whose listener ignores everything -- no `if listener` guard anywhere.
      #
      # `(**)` swallows `from:`/`to:`/`event:` without naming them, which both
      # states the "ignore it all" intent and keeps the keywords out of the
      # signature where an underscore prefix would silently rename them.
      module Null
        module_function

        def on_transition(**) = nil
      end
    end
  end
end
