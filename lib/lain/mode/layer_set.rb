# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  class Mode
    # The set of layers active right now. Emacs states order-independence as a
    # convention; here it is a property: `#|` is a commutative, idempotent
    # monoid whose unit is the empty set, so the set of active layers determines
    # behavior and the sequence that produced it does not. Deeply frozen and
    # `Ractor.shareable?`.
    class LayerSet
      include Enumerable
      include Inspectable

      # Canonicalized by SELECTING from the declaration order rather than by
      # sorting the input, so two sets holding the same layers are `==` however
      # they were built and iteration yields precedence order.
      #
      # @param names [Enumerable] layer names, in any order, with any repeats
      # @raise [ArgumentError] through {Layer.for} on an undeclared name
      def initialize(names = [])
        requested = names.map { |name| Layer.for(name).name }
        @names = Layer::NAMES.select { |name| requested.include?(name) }.freeze
        freeze
      end

      # @return [Array<Symbol>] the active layer names, in declaration order
      attr_reader :names

      def self.empty = EMPTY

      # The set IS its names, in declaration order, so the Enumerable surface
      # is theirs rather than a walk this object reimplements.
      delegate :each, :empty?, :size, to: :names

      def layers = names.map { |name| Layer.for(name) }

      def include?(name) = names.include?(Layer.for(name).name)

      # Reconstructed from the names rather than delegated to `#|`, so the
      # order-independence specs and the union laws stay independent claims: a
      # degenerate `#|` cannot be hidden by an `#enable` that agrees with it.
      def enable(name) = self.class.new(names + [name])

      # Disabling a layer that was never enabled is a no-op, not an error. An
      # UNDECLARED name still raises: that is a typo, not a request to remove
      # nothing.
      def disable(name) = self.class.new(names - [Layer.for(name).name])

      def |(other) = self.class.new(names + other.names)
      alias union |

      # `instance_of?` and not `is_a?`: the sibling this borrows its
      # frozen-sorted-symbol-set shape from, {Capability::DegradedSet}, writes
      # `is_a?`, and under subclassing that makes `parent == child` hold while
      # `child == parent` does not -- a live ==/hash violation once `hash`
      # embeds the class. {Lain::Toolset} is the corrected form, followed here.
      # Converging DegradedSet and {Lain::ContentAddressed} onto `instance_of?`
      # is owed; until it lands, the three differ on purpose.
      def ==(other) = other.instance_of?(self.class) && names == other.names
      alias eql? ==

      def hash = [self.class, names].hash

      # inspect keeps the class-tagged debug form -- the DegradedSet convention.
      def to_s = names.join(", ")

      # The monoid's unit, built once: a fresh empty set per call would be a
      # fresh allocation for a value that can never differ.
      EMPTY = new
    end
  end
end
