# frozen_string_literal: true

module Lain
  module Budget
    # Per-kind limits, each an Integer, BigDecimal or nil (unlimited). A meet
    # semilattice under "at least as tight", with the all-nil value as the top.
    Ceilings = Data.define(:iterations, :tokens, :dollars, :width, :depth) do
      def self.unlimited = new(iterations: nil, tokens: nil, dollars: nil, width: nil, depth: nil)

      def meet(other)
        self.class.new(**to_h.merge(other.to_h) { |_kind, mine, theirs| [mine, theirs].compact.min })
      end

      def descend
        with(depth: depth && [depth - 1, 0].max)
      end

      # A nil in the request inherits this holder's room and a finite one is
      # clamped to it, so a child never outranks its spawner.
      # @raise [Lain::Budget::Ceilings::Unrunnable] when the child would have no iterations or no depth
      def attenuate(requested)
        child = descend.meet(requested)
        kind = %i[iterations depth].find { |limit| child.to_h[limit]&.zero? }
        raise self.class::Unrunnable, kind if kind

        child
      end
    end

    class Ceilings
      UNLIMITED = unlimited

      # Raised with the kind of ceiling that left a child no room to run.
      class Unrunnable < Lain::Error
        attr_reader :kind

        def initialize(kind)
          @kind = kind
          super("a child with no #{kind} cannot run")
        end
      end
    end
  end
end
