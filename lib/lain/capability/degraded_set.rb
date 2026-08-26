# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/delegation"

module Lain
  module Capability
    # The set of capabilities a run silently lost because its policy was
    # `:degrade`. A value object, not a bag of symbols, because it is the thing
    # `Compare` compares: two runs are only comparable when their degraded sets
    # are EQUAL, and equality must not depend on the order the capabilities
    # happened to degrade in. Hence sorted + deduplicated at construction, so
    # equality and `hash` are structural.
    #
    # Deeply frozen and `Ractor.shareable?` -- the same mechanical guarantee the
    # Timeline's turns carry.
    class DegradedSet
      include Enumerable
      include Inspectable

      # @return [Array<Symbol>] sorted, unique
      attr_reader :capabilities

      # @param capabilities [Enumerable] anything answering #to_sym per element
      def initialize(capabilities)
        @capabilities = capabilities.map(&:to_sym).uniq.sort.freeze
        freeze
      end

      def each(&block) = capabilities.each(&block)

      delegate :empty?, to: :capabilities

      def to_a = capabilities

      # ==/eql?/hash agree, and must: a == pair that hashed differently breaks
      # Hash/Set membership. `is_a?(self.class)` mirrors the ContentAddressed
      # convention -- a duck with a matching `capabilities` is not this value.
      # Both that guard and the class-embedding `hash` are receiver-class
      # directional under subclassing (parent == child but not the reverse, and
      # their hashes differ); no production subclass exists, so it is latent.
      def ==(other)
        other.is_a?(self.class) && capabilities == other.capabilities
      end
      alias eql? ==

      def hash = [self.class, capabilities].hash

      # The human-facing list; `inspect` keeps the class-tagged debug form.
      def to_s = capabilities.join(", ")
    end
  end
end
