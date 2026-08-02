# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # Two strategies over one span, run as one: `elide | summarize` collapses
      # the tool stretches by attestation and the conversational ones by
      # summary, in a single derivation, and the turns neither claims are
      # retained verbatim in the gaps between them.
      #
      # == Why it exists at all
      #
      # `chunk-derived-context-timeline.md` follow-up 3 designed this and
      # deferred it as speculative generality. Joel un-deferred it on
      # 2026-07-29 with the reason recorded here rather than in the plan:
      # BUILDING IT IS WHAT PROVES THE EXTRACTION. {IntervalPartition} was
      # pulled out of {Base} for three callers, and this is the third -- the one
      # that needs the value's refinement meet, which nothing else does, and the
      # one that would have had to reach into a private constant to exist.
      #
      # == It is PARTIAL, and the partiality is the contract
      #
      # Two strategies compose only when they claim DISJOINT stretches. There is
      # no sensible winner for a range both want -- collapsing it twice writes
      # two replacement events over one preimage, and picking one silently
      # discards a policy an operator asked for -- so an overlap refuses,
      # naming both operands and the indices they both claimed. Those indices
      # are exactly {IntervalPartition#meet}: two proposals are composable when
      # their common refinement is empty.
      #
      # == The dispatch is stateless
      #
      # A strategy must stay frozen and `Ractor.shareable?` ({Scheduler::COMPOSE}
      # enforces it), so "which operand proposed this range" can live neither in
      # an ivar nor in a memo. It lives on the RANGE: {Owned} is a Range
      # subclass carrying its proposer, {IntervalPartition} answers an
      # already-inclusive range by identity, and {Derivation}'s fold hands back
      # the very object it was given -- so the tag survives the round trip with
      # no memo and no matching of slice contents. Ranges never pass through
      # {Canonical} (they live inside one turn's derivation), so the
      # Hash-subclass erasure that ruled out a subclassed content block does not
      # reach them.
      #
      # It is one more subclass of {Base} and not a new seam: {#ranges} and
      # {#collapse} stay Base's, sealed, and the whole of what this class adds
      # is a proposal that merges two and a {Base#blocks_for} that forwards.
      class Composed < Base
        # Two operands claiming the same index. A kind of {NotAPartition} --
        # their union is not one -- so every existing rescue site catches it
        # while the name still says which of the seven conditions was met and
        # by whom. Written out in full because this file loads BEFORE
        # `strategy.rb`'s own `NotAPartition` alias is assigned.
        class Overlap < IntervalPartition::NotAPartition; end

        # A collapse asked about a slice this strategy never proposed, and so
        # cannot route. Loud, because the alternative is a NoMethodError on nil
        # from inside the dispatch, naming nobody.
        class Untagged < Error; end

        # A range that remembers which strategy proposed it. Frozen at
        # construction: a Range SUBCLASS is not frozen the way a Range literal
        # is, and an unfrozen one reachable from a partition would cost that
        # value its shareability.
        class Owned < Range
          # The innermost proposer keeps the tag: a nested composition re-reads
          # its operands' ranges, and re-tagging them with the intermediate
          # would make `(a | b) | c` dispatch differently from `a | (b | c)`.
          def self.of(range, owner) = range.is_a?(Owned) ? range : new(range.first, range.max, owner)

          attr_reader :owner

          def initialize(first, last, owner)
            super(first, last)
            @owner = owner
            freeze
          end
        end

        # @param left [Base] either operand; the order is immaterial, which is
        #   the commutativity law this class declares on {Base}
        def initialize(left, right)
          super()
          @left = left
          @right = right
          # SHALLOW, {Source::Derived::PinCuts}' discipline: it fixes this
          # object's own two references and says nothing about the operands,
          # either of which may legitimately hold a live oracle and a mutable
          # memo and must NOT be frozen.
          freeze
        end

        # Both, so the journalled derivation edge and every refusal say which
        # two policies ran. Interned for the reason {Base#name} is.
        def name = -"#{@left.name} | #{@right.name}"

        def hits = @left.hits + @right.hits

        def misses = @left.misses + @right.misses

        # Both operands' proposals, tagged and merged, when they are disjoint.
        # Ascending because {Base#ranges} would refuse them otherwise, and
        # ascending is also what makes the fold's output independent of which
        # operand was written first.
        def propose_ranges(messages, span:)
          proposed = [@left, @right].map { |strategy| [strategy, strategy.ranges(messages, span:)] }
          refuse_overlap(span, proposed)
          proposed.flat_map { |strategy, ranges| ranges.map { |range| Owned.of(range, strategy) } }
                  .sort_by(&:first)
        end

        # Every leaf under this composition, in proposal order -- and never
        # `[self]`, which is what {Base#operands} answers for a strategy that is
        # made of nothing but itself.
        def operands = @left.operands + @right.operands

        # Routed by the tag the proposal carried, never by the slice: two
        # operands can legitimately answer identical messages, and matching on
        # content would pick whichever was asked first.
        #
        # The owner COLLAPSES its own range and this re-wraps the content, which
        # costs one extra pass of {Replacement}'s vetting and buys the thing a
        # forwarded `#blocks_for` cannot: a {NotBlocks} or a {Blank} names the
        # operand that actually answered. Forwarding raised them against the
        # pair -- "strategy `Elide | Mute` answered nil" -- which is findable and
        # literally false about one of the two.
        def blocks_for(messages, range)
          refuse_untagged(range)
          range.owner.collapse(messages, range:).content
        end

        private

        # Asked of the VALUE that owns the shape: two proposals are composable
        # exactly when their common refinement is empty, and the refinement is
        # also the list of indices a refusal has to name.
        def refuse_overlap(span, proposed)
          shared = proposed.map { |strategy, ranges| IntervalPartition.of(span, ranges, owner: strategy.name) }
                           .inject(:meet).validated
          return if shared.empty?

          raise Overlap, "#{@left.name} and #{@right.name} both propose #{listed(shared)}; strategies compose " \
                         "only over DISJOINT stretches, since collapsing one range twice would write two " \
                         "replacements over one preimage"
        end

        # The OWNER and not merely the tag: an {Owned} minted by a different
        # composition, or by nobody, carries a strategy this one does not hold,
        # and forwarding to it would collapse the range through a stranger in
        # silence. `is_a?(Owned)` alone does not make the claim this message
        # makes.
        def refuse_untagged(range)
          return if range.is_a?(Owned) && operands.any? { |operand| operand.equal?(range.owner) }

          raise Untagged, "#{name} is asked to collapse #{range.inspect}, which neither operand proposed; a " \
                          "composed strategy routes a collapse by the range its proposal tagged"
        end

        def listed(ranges) = ranges.map(&:inspect).join(", ")
      end
    end
  end
end
