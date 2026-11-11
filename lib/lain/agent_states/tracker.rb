# frozen_string_literal: true

module Lain
  module AgentStates
    # The one fold of agent states per chat, riding the chat's tee as a `#<<` sink. The status feed
    # publishes what it holds and notice logic hears its changes, so neither folds the records again.
    #
    # It never raises into the tee: a record that fails to fold is skipped and an observer that fails
    # is skipped for that change alone, because either would cost the agent its turn over a status line.
    class Tracker
      # @!attribute [r] rollup
      #   @return [Symbol] the most urgent state of any agent after the change
      # @!attribute [r] agent
      #   @return [Journal::Projection::AgentStates::Agent] the agent whose state moved
      # @!attribute [r] since
      #   @return [Float] the clock's elapsed seconds when it moved
      Change = Data.define(:rollup, :agent, :since)

      # @param clock [#elapsed] the run's {RunClock}
      def initialize(clock:)
        @clock = clock
        @projection = Journal::Projection::AgentStates.unit
        @observers = []
      end

      # @return [Journal::Projection::AgentStates] the fold so far
      attr_reader :projection

      # @param record [Object] any tee event; one the fold does not read changes nothing
      # @return [self]
      def <<(record)
        advance(record)
        self
      end

      # The human looked at a finished agent.
      #
      # @param agent [String, nil] nil for every finished agent
      # @return [self]
      def seen(agent = nil) = self << Seen.new(agent:)

      # @yieldparam change [Change]
      # @return [self]
      def on_change(&observer)
        @observers << observer
        self
      end

      private

      def advance(record)
        before = @projection.agents
        @projection = @projection.step(record)
        announce(before)
      rescue StandardError
        nil
      end

      def announce(before)
        known = before.to_h { [_1.id, _1] }
        @projection.agents.reject { known[_1.id] == _1 }.each do |agent|
          tell(Change.new(rollup: @projection.rollup, agent:, since: @clock.elapsed))
        end
      end

      def tell(change)
        @observers.each do |observer|
          observer.call(change)
        rescue StandardError
          nil
        end
      end
    end
  end
end
