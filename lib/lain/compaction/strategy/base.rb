# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # The name this namespace keeps for {IntervalPartition::NotAPartition}.
      # The error belongs to the VALUE -- a lib-level value raising a
      # compaction-namespaced error would invert the dependency -- but every
      # rescue site and spec that learned this name reaches it here.
      NotAPartition = IntervalPartition::NotAPartition

      # The contract every span-collapse strategy implements: which sub-spans of
      # the droppable span it will collapse, and what replaces one.
      #
      #   propose_ranges(messages, span:) -> Array<Range>
      #   blocks(messages)                -> Array<Hash>
      #
      # ...and the two questions a CALLER asks, neither of which a strategy
      # writes:
      #
      #   ranges(messages, span:)        -> Array<Range>  # the proposal, validated
      #   collapse(messages, range: nil) -> Replacement   # the blocks, wrapped
      #
      # Both hooks raise {NotImplementedError} NAMING the implementer, so a
      # strategy that implements neither fails at the first span it is offered
      # rather than silently doing nothing. (`NotImplementedError <
      # ScriptError`, so a `rescue StandardError` around a strategy call does
      # NOT catch it.)
      #
      # == Why the public questions are not the hooks
      #
      # Because a caller must not be able to reach an unvalidated answer. The
      # derivation's causal edges are the FIBRE of the collapse, so a range list
      # that overlaps or escapes its span silently corrupts that preimage.
      # Making {#ranges} the validated question and {#propose_ranges} the hook
      # means the obvious call is the safe one, and the unsafe one is named like
      # something you implement rather than something you call.
      #
      # The same reasoning is why there is no `#call(messages) -> messages`:
      # that is {Context::Combinator}'s shape, and a strategy that can rewrite
      # the whole array has no preimage at all. A strategy is asked about
      # MESSAGES and never about a Timeline, a Session or an Event.
      #
      # == The two questions are SEALED
      #
      # {#ranges} and {#collapse} cannot be redefined by a subclass;
      # `method_added` refuses both doors at load. Not defensiveness: a
      # subclass whose {#collapse} answered an Array would hand every consumer
      # expecting a {Replacement} the wrong thing, and {Replacement} could not
      # name whose fault it was.
      #
      # == Where the algebra attaches
      #
      # {#collapse} answers a {Replacement}, which is not a monoid element, so
      # the laws are read over {#blocks}: content blocks in the free monoid,
      # whose unit is DROP. An elementwise strategy writes {#blocks} as the
      # concatenation of a per-message map -- {Elide} is the shape -- and by the
      # universal property of the free monoid that is a monoid homomorphism.
      # Purity is the orthogonal axis. Each strategy's spec holds it to the laws
      # it obeys and exhibits the ones it does not.
      class Base
        # What a subclass may not redefine, and what to write instead.
        SEALED = { ranges: "#propose_ranges, which #ranges validates", collapse: "#blocks" }.freeze

        # What a refusal cites as the source of the ranges it refused. Supplied
        # here because THIS is the caller that called the hook: a partition
        # built from cut points or from a refinement names its own constructor
        # instead, so no refusal sends a reader to a hook nobody called.
        HOOK = "#propose_ranges"

        # Interned, because an anonymous class's `to_s` is a freshly built
        # MUTABLE String and this name is reachable from values that have to
        # stay shareable.
        def name = -(self.class.name || self.class.to_s)

        # How many ranges this strategy answered from an address it already
        # held, and how many it had to work for. Answered by EVERY strategy
        # rather than only by the ones that hold something, so a
        # {Compaction::Source} journalling the rate needs no `respond_to?` in
        # front of the one policy that does not.
        #
        # The counts matter because a mis-keyed content address is invisible
        # EXCEPT as a hit count that never rises.
        def hits = 0

        def misses = 0

        # @param messages [Array<Hash>] the rendered messages
        # @param span [Range] the droppable span, as message indices
        # @return [Array<Range>] the sub-spans to collapse: ascending,
        #   non-overlapping, all inside `span`, and in {IntervalPartition}'s
        #   canonical inclusive spelling whatever the hook proposed. Empty means
        #   "collapse nothing", which is how a strategy declines a turn.
        def ranges(messages, span:)
          IntervalPartition.of(span, propose_ranges(messages, span:), owner: name, provenance: HOOK).validated
        end

        # The hook {#ranges} validates. Implement this; call that. Public only
        # because a subclass overrides it -- its answer has been checked by
        # nobody, and the derivation's causal edges are what pay for that.
        def propose_ranges(_messages, span:)
          raise NotImplementedError,
                "strategy #{name} must implement #propose_ranges(messages, span: #{span.inspect}) -> Array<Range>"
        end

        # @param messages [Array<Hash>] one range's worth of messages
        # @return [Array<Hash>] the content blocks that replace them
        def blocks(messages)
          raise NotImplementedError, "strategy #{name} must implement #blocks(messages) -> Array<Hash>"
        end

        # Two strategies claiming disjoint stretches of one span, run as one: a
        # commutative monoid with {Identity} as its unit. Spelled `|` because it
        # takes the UNION of two range-sets, and because the partiality reads as
        # a set operation: an overlap refuses rather than picking a winner.
        def |(other) = Composed.new(self, other)

        # @param messages [Array<Hash>] one range's worth of messages
        # @param range [Range, nil] which sub-span they were sliced from;
        #   {Derivation}'s fold holds it and passes it through. nil is "a slice
        #   nobody proposed", which is how every direct caller asks.
        # @return [Replacement] what replaces one range -- DROP if the collapse
        #   answers no blocks, since that is the unit of the monoid {#blocks}
        #   maps into rather than a blank replacement.
        def collapse(messages, range: nil) = Replacement.of(answered_blocks(messages, range))

        # The blocks for ONE proposed range, which is where composition enters.
        # It is separate from {#blocks} so that {#blocks} keeps its one-argument
        # shape: an elementwise strategy's is a concatenation over messages, and
        # a range is a parameter no per-message map can use.
        #
        # {Composed} is the one strategy that overrides it, because a range it
        # answers was proposed by one of its two operands and only that operand
        # can collapse it. Public so a composition can forward to the operand
        # that owns the range without reaching through its visibility.
        def blocks_for(messages, _range) = blocks(messages)

        # The strategies this one is made of: itself, for anything that is not a
        # composition. It is what lets {Composed} check that a range it is asked
        # to collapse was tagged by one of its own leaves rather than merely
        # carrying a tag.
        def operands = [self]

        # Defined LAST, so Base's own definitions above are not refused by it,
        # and on the singleton so it fires for every subclass -- including one
        # written by `define_method`.
        def self.method_added(name)
          super
          instead = SEALED[name]
          return if instead.nil?

          # A subclass redefining one of the two methods {Base} defines FOR it.
          raise Error, "#{self} redefines ##{name}, which Strategy::Base defines once for every strategy " \
                       "so that a caller cannot reach an unvalidated answer; implement #{instead}"
        end

        private

        # {Replacement} would catch a wrong shape a moment later but cannot name
        # whose fault it is.
        def answered_blocks(messages, range)
          answered = blocks_for(messages, range)
          return answered if answered.is_a?(Array)

          raise NotBlocks, "strategy #{name} answered #{answered.inspect} from #blocks; " \
                           "expected an Array of content blocks"
        end
      end
    end
  end
end
