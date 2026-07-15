# frozen_string_literal: true

module Lain
  # Prompt slots: named holes in the base prompt, filled by markdown partials,
  # rendered in a purity-enforcing binding. See {Prompt::Slots}.
  module Prompt
    class Error < Lain::Error; end

    # A `.lain/slots/` file whose name matches no known slot -- a typo surfaced
    # loudly (naming the file and the known slots) rather than silently ignored.
    class UnknownSlot < Error; end

    # A partial referenced something impure -- a constant, a subshell, or a
    # side-effecting call -- and was rejected before evaluation, so the prompt can
    # never carry a silently nondeterministic value.
    class ImpureSlot < Error; end

    # A slot fill that renders itself, caught before it overflows the stack.
    class CircularSlot < Error; end
  end
end

# Children reference the error classes above, so the module body loads first --
# the effect/handler ordering pattern, not the context/combinator one.
require_relative "prompt/locked_binding"
require_relative "prompt/slots"
