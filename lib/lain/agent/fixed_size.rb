# frozen_string_literal: true

module Lain
  class Agent
    # The bytes of a request that no compaction can drop: the system text and
    # the tool schemas, in the same canonical byte proxy {Compaction::Head}
    # measures the droppable history in.
    #
    # Measured once per (system, toolset) pair rather than per render, because
    # neither changes between turns and a Canonical dump of every tool schema
    # is not free. The pair is compared by identity: a `/model` or persona swap
    # hands a different Context, hence a different system, and a stale size
    # would silently mis-trigger.
    #
    # Reminders are not counted: they ride in the messages, which the head
    # already measures, and they are rendered per turn from the Session.
    class FixedSize
      Measured = Data.define(:system, :toolset, :bytes) do
        def of?(held_system, held_toolset) = system.equal?(held_system) && toolset.equal?(held_toolset)
      end
      private_constant :Measured

      def initialize
        @measured = nil
      end

      # @param system [String, Array, nil] compared by identity, so a swapped prompt is re-measured
      # @param toolset [Toolset]
      # @return [Integer]
      def bytes(system:, toolset:)
        @measured = measure(system, toolset) unless @measured&.of?(system, toolset)
        @measured.bytes
      end

      private

      def measure(system, toolset)
        Measured.new(system:, toolset:, bytes: Canonical.dump([system, toolset.to_schema]).bytesize)
      end
    end
  end
end
