# frozen_string_literal: true

module Lain
  class FileLock
    # The try stays the caller's, so a wait whose every try must run under
    # another lock keeps that lock in its own hands.
    class Wait
      # @param patience [Numeric] seconds of waiting before the notice
      # @param interval [Numeric] seconds between tries
      # @param sleeper [#call] waits between tries
      # @param clock [#call] the monotonic reading patience and deadline are measured against
      def initialize(patience:, interval:, sleeper: Kernel.method(:sleep), clock: RunClock::MONOTONIC)
        @patience = patience
        @interval = interval
        @sleeper = sleeper
        @clock = clock
        freeze
      end

      # @param notice [#call] called with no arguments, once, when the wait outlasts the patience
      # @param deadline [Numeric] seconds after which the wait gives up; never, when infinite
      # @yieldreturn [Boolean] truthy once the try got what it wanted
      # @return [Boolean] whether a try succeeded before the deadline
      def succeeded?(notice, deadline: Float::INFINITY)
        started = @clock.call
        told = false
        until yield
          elapsed = @clock.call - started
          return false if elapsed >= deadline

          told ||= told?(notice, elapsed)
          @sleeper.call([@interval, deadline - elapsed].min)
        end
        true
      end

      private

      def told?(notice, elapsed)
        return false if elapsed < @patience

        notice.call
        true
      end
    end
  end
end
