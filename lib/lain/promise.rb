# frozen_string_literal: true

require "async/variable"

module Lain
  # A single-assignment value that a fiber can await before it is set. The thin
  # domain-named wrapper over `Async::Variable` that ask_human (OM-4) resolves:
  # naming it in our own vocabulary keeps callers depending on the message
  # (`resolve`/`await`/`resolved?`) rather than on the gem's type, so the awaited
  # value is the seam the actor mailbox (OM-3) and speculative branching (3c-5.6)
  # can reuse without importing `async` at every call site.
  #
  # The one property everything rests on: `#await` parks the calling FIBER, not
  # the reactor. An unresolved promise yields the fiber back to the scheduler, so
  # concurrent work proceeds while one fiber waits -- which is why ask_human can
  # both gate synchronously (await immediately) and continue asynchronously
  # (await later) from one mechanism.
  #
  # Resolution is single-shot and loud. `Async::Variable#resolve` freezes itself,
  # so a second resolve would surface as an incidental `FrozenError`; we raise
  # {AlreadyResolved} instead, because a promise resolved twice is a coordination
  # bug this project's premise says must fail in its own words, not by accident.
  class Promise
    class AlreadyResolved < Error; end

    def initialize(variable = Async::Variable.new)
      @variable = variable
    end

    # Set the value, waking every fiber parked in {#await}. Raises
    # {AlreadyResolved} if the promise was already resolved.
    def resolve(value)
      raise AlreadyResolved, "promise already resolved" if @variable.resolved?

      @variable.resolve(value)
    end

    # Whether the value has been set. A resolved promise's {#await} returns at
    # once; an unresolved one's parks the caller.
    def resolved?
      @variable.resolved?
    end

    # Block the calling fiber until resolved, then return the value. Returns
    # immediately when the promise is already resolved -- the degenerate sync
    # case ask_human's gate falls out of.
    def await
      @variable.value
    end
  end
end
