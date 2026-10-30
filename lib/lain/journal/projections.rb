# frozen_string_literal: true

module Lain
  class Journal
    # Several projections stepped together, so a reader that wants several parses the file once.
    # Its {#value} is the Hash of member projections by key, not their values: read a member's
    # value through {#[]}.
    class Projections < Projection
      # @param projections [Hash{Symbol=>Projection}] each member's starting state
      # @return [Projections]
      def self.of(**projections) = new(projections)

      # The composite of no members, so the class-level {.over} folds to an empty composite: a
      # composite with members is folded from {.of} through {#over}.
      #
      # @return [Projections]
      def self.unit = of

      # @param record [Telemetry::Journalable, Telemetry::Untyped]
      # @return [Projections] self when no member moved
      def step(record)
        stepped = state.transform_values { |projection| projection.step(record) }
        stepped.all? { |key, projection| projection.equal?(state[key]) } ? self : self.class.new(stepped)
      end

      # @param key [Symbol]
      # @return [Projection]
      # @raise [KeyError] for a key the composite does not hold
      def [](key) = state.fetch(key)
    end
  end
end
