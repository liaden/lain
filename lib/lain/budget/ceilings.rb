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

      # Checked after each response, once its price is known.
      # @raise [Lain::Budget::Exceeded] when the priced part of the spend has passed the dollar ceiling
      def check_dollars!(spent)
        raise dollars_refusal(spent) if dollars && spent.dollars.amount > dollars
      end

      # @return [Lain::Budget::Exceeded] the refusal naming dollars and the priced amount spent
      def dollars_refusal(spent)
        gap = spent.dollars.complete? ? "" : " (unpriced turns not counted)"
        Exceeded.new("spent #{spent.dollars.amount.to_s("F")} dollars, ceiling is #{dollars.to_s("F")}#{gap}",
                     kind: :dollars)
      end

      # A nil in the request inherits this holder's room and a finite one is
      # clamped to it, so a child never outranks its spawner in tokens, dollars,
      # width or depth. Iterations are the exception: a role's own ceiling is its
      # shape (a researcher walks many files), so the request stands whatever the
      # spawning ask has left, and only a nil request inherits. Depth is what the
      # holder may still spawn below itself, so a child at 0 runs as a leaf, and
      # depth alone bounds recursion now that iterations do not shrink.
      # @raise [Lain::Budget::Ceilings::Unrunnable] when the holder has no depth or the child no iterations or dollars
      def attenuate(requested)
        raise self.class::Unrunnable, :depth if depth&.zero?

        child = descend.meet(requested).with(iterations: requested.iterations || iterations)
        raise self.class::Unrunnable, :iterations if child.iterations&.zero?
        raise self.class::Unrunnable, :dollars if child.dollars && !child.dollars.positive?

        child
      end
    end

    class Ceilings
      UNLIMITED = unlimited

      # Raised with the kind of ceiling that left no room for a child.
      class Unrunnable < Lain::Error
        WHY = { depth: "this agent has no spawn depth left",
                iterations: "a child with no iterations cannot run",
                dollars: "a child with no dollars left cannot run" }.freeze

        attr_reader :kind

        def initialize(kind)
          @kind = kind
          super(WHY.fetch(kind))
        end
      end
    end
  end
end
