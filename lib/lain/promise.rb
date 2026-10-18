# frozen_string_literal: true

require "async/promise"

module Lain
  # A single-assignment value a fiber can await before it is set. A thin
  # domain-named wrapper over `Async::Promise`, so callers depend on the
  # message rather than on the gem's type and nothing imports `async` at the
  # call site.
  #
  # The property everything rests on: `#await` parks the calling FIBER, not the
  # reactor, so concurrent work proceeds while one fiber waits. That is why
  # ask_human can gate synchronously and continue asynchronously from one
  # mechanism.
  #
  # `Async::Promise#resolve` ignores a second call in silence;
  # {AlreadyResolved} is raised instead, because a promise resolved twice is a
  # coordination bug and must fail in its own words.
  class Promise
    class AlreadyResolved < Error; end

    def initialize
      @promise = Async::Promise.new
      @lock = Mutex.new
    end

    # Set the value, waking every fiber parked in {#await}. Raises
    # {AlreadyResolved} if the promise was already resolved.
    def resolve(value)
      @lock.synchronize do
        raise AlreadyResolved, "promise already resolved" if @promise.resolved?

        @promise.resolve(value)
      end
    end

    # @return [Boolean] whether the value has been set
    def resolved?
      @promise.resolved?
    end

    # Parks the calling fiber until resolved. Returns immediately when already
    # resolved -- the degenerate sync case ask_human's gate falls out of.
    def await
      @promise.wait
    end
  end
end
