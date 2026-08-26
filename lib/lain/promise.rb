# frozen_string_literal: true

require "async/variable"

module Lain
  # A single-assignment value a fiber can await before it is set. A thin
  # domain-named wrapper over `Async::Variable`, so callers depend on the
  # message rather than on the gem's type and nothing imports `async` at the
  # call site.
  #
  # The property everything rests on: `#await` parks the calling FIBER, not the
  # reactor, so concurrent work proceeds while one fiber waits. That is why
  # ask_human can gate synchronously and continue asynchronously from one
  # mechanism.
  #
  # `Async::Variable#resolve` freezes itself, so a second resolve would surface
  # as an incidental `FrozenError`; {AlreadyResolved} is raised instead, because
  # a promise resolved twice is a coordination bug and must fail in its own
  # words.
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

    # @return [Boolean] whether the value has been set
    def resolved?
      @variable.resolved?
    end

    # Parks the calling fiber until resolved. Returns immediately when already
    # resolved -- the degenerate sync case ask_human's gate falls out of.
    def await
      @variable.value
    end
  end
end
