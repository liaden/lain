# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/delegation"

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

      delegate :empty?, to: :capabilities

      def to_a = capabilities

      # ==/eql?/hash agree, and must: a == pair that hashed differently breaks
      # Hash/Set membership -- table stakes for a value object, whatever compares
      # it. (`Compare` today checks equality pairwise via `Guard.guard!`, a plain
      # ==; the hash contract is general Hash/Set semantics, not its mechanism.)
      # `is_a?(self.class)` mirrors the ContentAddressed convention -- a duck with
      # a matching `capabilities` is not this value. Caveat: both the guard and the
      # class-embedding `hash` are receiver-class-directional under subclassing
      # (parent == child but not the reverse, and their hashes differ); no
      # production subclass exists today, so the asymmetry is latent.
      def ==(other)
        other.is_a?(self.class) && capabilities == other.capabilities
      end
      alias eql? ==

      def hash = [self.class, capabilities].hash

      # to_s is the human-facing capability list; inspect keeps the class-tagged,
      # debug-oriented form.
      def to_s = capabilities.join(", ")

      def inspect = "#<#{self.class} #{capabilities.join(", ")}>"
    end
  end
end
