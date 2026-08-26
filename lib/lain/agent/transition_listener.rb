# frozen_string_literal: true

module Lain
  class Agent
    # The seam observability hangs from. Every state change is announced here as
    # `(from:, to:, event:)` before it takes effect, so the Journal can subscribe
    # without the Agent knowing anything listens.
    #
    # This is why `state_machines` was chosen over a hand-rolled `@state`: a
    # declared machine gives the transition a single interceptable moment, where
    # a scattered `@state = :x` has no such hook.
    module TransitionListener
      # Null object, so no caller writes `if listener`.
      #
      # `(**)` swallows `from:`/`to:`/`event:` without naming them -- an
      # underscore prefix on a keyword argument silently renames it.
      module Null
        module_function

        def on_transition(**) = nil
      end
    end
  end
end
