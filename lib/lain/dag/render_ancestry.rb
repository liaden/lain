# frozen_string_literal: true

module Lain
  module Dag
    # The render order: `a` is below `b` when `a`'s head lies on `b`'s render
    # chain. Under it the Timelines over one Store form a meet semilattice --
    # {.meet} is the greatest common ancestor and the empty Timeline is the
    # bottom, which is what keeps the meet total for two members that share no
    # history. Causal edges are invisible here on purpose: cache-break
    # localization needs an answer that stays stable as causal edges land.
    module RenderAncestry
      module_function

      def meet(one, other)
        Dag.same_store!(one, other)
        mine = one.ancestor_digests.to_h { |digest| [digest, true] }
        # `mine` has to see the whole of one side's history to answer "is this
        # digest in my history" at all -- that side cannot stop early. The
        # other can: walking Event objects (not `ancestor_digests`, which maps
        # the whole Array first) lets `#find` stop the instant it lands on
        # shared history, instead of continuing on toward its own root.
        common = other.ancestors.find { |turn| mine.key?(turn.digest) }
        one.checkout(common&.digest)
      end

      # The event where two branches diverged, or nil if they share no history.
      def diverge_at(one, other) = meet(one, other).head

      # {Timeline#ancestor_of?} IS this order's predicate; it stays on the
      # Timeline because a chain walk is the Timeline's own vocabulary.
      def below?(one, other) = one.ancestor_of?(other)
    end
  end
end
