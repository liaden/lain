# frozen_string_literal: true

module Lain
  class Journal
    # One reader's fold over a session's records, as a frozen value. A subclass names its
    # {.unit} and its {#step}; {.over} is the inject. Records arrive as {Telemetry.read}
    # answers them, so a step dispatches on class, and the same projection folds a file whole,
    # a file followed live through a {Tail}, or a live Channel.
    #
    # Stepping answers a new projection and leaves the receiver as it was: a state handed to
    # another reader cannot move under it. A step that ignores a record may answer self.
    #
    # A projection whose halves fold apart and combine to the whole declares `#combine`. One that
    # binds a record to a later one, as a read binds to the turn after it, with a state that drops
    # the later record's key, cannot.
    class Projection
      # @return [Projection] the fold over no records
      # @raise [NotImplementedError] for a projection that names none
      def self.unit = raise(NotImplementedError, "#{name || self} names no unit")

      # @param records [Enumerable<Telemetry::Journalable, Telemetry::Untyped>]
      # @return [Projection]
      def self.over(records) = unit.over(records)

      # @return [Object] deeply frozen
      attr_reader :state

      # @param state [Object] made shareable, which freezes it in place
      def initialize(state)
        @state = Ractor.make_shareable(state)
        freeze
      end

      # The fold continued from here, which is what a reader following a file live does.
      #
      # @param records [Enumerable<Telemetry::Journalable, Telemetry::Untyped>]
      # @return [Projection]
      def over(records) = records.inject(self) { |projection, record| projection.step(record) }

      # @param record [Telemetry::Journalable, Telemetry::Untyped]
      # @return [Projection]
      def step(record) = raise(NotImplementedError, "#{self.class} cannot step #{record.class}")

      # @return [Object] what a reader wants; the state unless the subclass says otherwise
      def value = state

      # @param other [Object]
      # @return [Boolean]
      def ==(other) = other.instance_of?(self.class) && other.state == state
      alias eql? ==

      # @return [Integer]
      def hash = [self.class, state].hash
    end
  end
end
