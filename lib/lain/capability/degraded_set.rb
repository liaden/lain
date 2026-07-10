# frozen_string_literal: true

module Lain
  module Capability
    # The set of capabilities a run silently lost because its policy was
    # `:degrade`. This is a value object, not a bag of symbols, because it is the
    # thing `Compare` compares: two runs are only comparable when their degraded
    # sets are EQUAL, and equality must not depend on the order the capabilities
    # happened to degrade in. Hence sorted + deduplicated at construction, so
    # equality and `hash` are structural.
    #
    # Deeply frozen and `Ractor.shareable?`: the members are Symbols (already
    # shareable) held in a frozen Array, and the object itself is frozen, so it
    # can cross a Ractor boundary uncopied -- the same mechanical guarantee the
    # Timeline's turns carry.
    class DegradedSet
      include Enumerable

      # @return [Array<Symbol>] sorted, unique
      attr_reader :capabilities

      # @param capabilities [Enumerable] anything answering #to_sym per element
      def initialize(capabilities)
        @capabilities = capabilities.map(&:to_sym).uniq.sort.freeze
        freeze
      end

      def each(&block) = capabilities.each(&block)

      def empty? = capabilities.empty?

      def to_a = capabilities

      def ==(other)
        other.is_a?(self.class) && capabilities == other.capabilities
      end
      alias eql? ==

      def hash = [self.class, capabilities].hash

      def to_s = "#<#{self.class} #{capabilities.join(", ")}>"
      alias inspect to_s
    end
  end
end
