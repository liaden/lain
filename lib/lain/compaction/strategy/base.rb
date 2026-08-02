# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # The name this namespace keeps for {IntervalPartition::NotAPartition}.
      # The conditions are the VALUE's, and so is the error -- a lib-level value
      # raising a compaction-namespaced error would invert the dependency the
      # extraction exists to fix -- but every rescue site and every spec that
      # learned this name reaches it here.
      NotAPartition = IntervalPartition::NotAPartition

      # A subclass redefining one of the two methods {Base} defines FOR it.
      class Sealed < Error; end

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
      # It is the sibling of {Summarizer::Base} one level up: that duck answers
      # two questions about a single tool result, this one answers two about a
      # SPAN. Both hooks raise {NotImplementedError} NAMING the implementer, in
      # the shape {Arm#run} uses, so a strategy that implements neither fails at
      # the first span it is offered rather than silently doing nothing. (Note
      # that `NotImplementedError < ScriptError`, so a `rescue StandardError`
      # around a strategy call does NOT catch it.)
      #
      # == Why the public questions are not the hooks
      #
      # Because a caller must not be able to reach an unvalidated answer. The
      # derivation's causal edges are the FIBRE of the collapse -- a replacement
      # event names the source events its range subsumed -- so a range list that
      # overlaps or escapes its span silently corrupts that preimage. Making
      # {#ranges} the validated question and {#propose_ranges} the hook means the
      # obvious call is the safe one, and the unsafe one has a name that reads as
      # something you implement rather than something you call.
      #
      # The same reasoning is why there is no `#call(messages) -> messages`. That
      # is {Context::Combinator}'s shape, and a strategy that can rewrite the
      # whole array has no preimage at all. A strategy is asked about MESSAGES
      # and never about a Timeline, a Session or an Event -- that state belongs
      # to the caller, and a strategy needing it takes it at construction.
      #
      # == The two questions are SEALED
      #
      # {#ranges} and {#collapse} are defined here once and cannot be redefined
      # by a subclass: `method_added` refuses both doors at load, naming the
      # offender and what to implement instead. This is not defensiveness for its
      # own sake. {Algebra::Elementwise} checks `instance_methods(false)` before
      # generating, so it happily generates over an INHERITED method -- which
      # means `elementwise on: :collapse` was accepted in silence and left
      # {#collapse} answering an Array where every consumer expects a
      # {Replacement}. The template method is the contract, and a contract a
      # subclass can quietly replace is a comment.
      #
      # == Where the algebra attaches, and what an includer writes
      #
      # {#collapse} answers a {Replacement}, which is not a monoid element, so it
      # is not the operation the algebra declares. {#blocks} is: content blocks
      # in the free monoid, whose unit is DROP, which is what F8 means by
      # "#collapse maps into the free monoid".
      #
      # An unconditionally elementwise strategy therefore writes only its
      # per-message map, and {Algebra::Elementwise} generates the span map over
      # it:
      #
      #   class Elide < Strategy::Base
      #     include Algebra::Elementwise
      #     include Algebra::Pure
      #
      #     def propose_ranges(_messages, span:) = [span]
      #
      #     private
      #
      #     def attested(message) = [{ "type" => "text", "text" => "..." }]
      #
      #     elementwise on: :blocks, each: :attested   # BELOW the helper it names
      #     pure on: :blocks
      #   end
      #
      # By the universal property of the free monoid such an includer is a monoid
      # homomorphism by construction -- `is_a?(Algebra::Elementwise)` IS the
      # classification, and there is no second declaration of the property here
      # to fall out of sync with it. Generating over the INHERITED {#blocks} is
      # ordinary subclassing and stays silent; a class that wrote its own
      # {#blocks} and then declared over it is refused ({Algebra::Occupied}).
      #
      # Purity is the orthogonal axis and is declared separately, per operation.
      # This class does NOT include {Algebra::Pure}: a strategy that holds an
      # oracle must be able to answer that it is not pure by not carrying the
      # vocabulary at all, and an includer must freeze itself to pass the
      # shareability proxy anyway.
      class Base
        include Algebra::CommutativeMonoid

        # What a subclass may not redefine, and what to write instead. The hint
        # is half the value: the mistake this catches is a reasonable one, made
        # by someone who read the card's duck section and not this file.
        SEALED = { ranges: "#propose_ranges, which #ranges validates",
                   collapse: "#blocks, or `elementwise on: :blocks`" }.freeze

        # What a refusal cites as the source of the ranges it refused. Supplied
        # here because THIS is the caller that called the hook: a partition built
        # from cut points or from a refinement names its own constructor instead,
        # so no refusal ever sends a reader to a hook nobody called.
        HOOK = "#propose_ranges"

        # The name this strategy answers to in errors and in the journalled
        # derivation edge. Interned, because an anonymous class's `to_s` is a
        # freshly built MUTABLE String (CLAUDE.md's named trap) and this name is
        # reachable from values that have to stay shareable.
        def name = -(self.class.name || self.class.to_s)

        # How many ranges this strategy answered from an address it already
        # held, and how many it had to work for. Zero here, and answered by
        # EVERY strategy rather than by the ones that hold something: a
        # {Compaction::Source} journalling the rate would otherwise carry a
        # `respond_to?` in front of the one policy that does not, which is the
        # `nil` guard CLAUDE.md's Null-Object rule exists to delete. A strategy
        # holding nothing has an honest rate of nothing, not an absent one.
        #
        # The counts matter because a mis-keyed content address is invisible
        # EXCEPT as a hit count that never rises ({Compaction::SummarySnapshot}'s
        # discipline, `summary_snapshot.rb:23-30`).
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

        # The hook {#ranges} validates. Implement this; call that. It is public
        # only because a subclass overrides it, and calling it is NOT the
        # contract: its answer has been checked by nobody, and the derivation's
        # causal edges are what pay for that.
        def propose_ranges(_messages, span:)
          raise NotImplementedError,
                "strategy #{name} must implement #propose_ranges(messages, span: #{span.inspect}) -> Array<Range>"
        end

        # @param messages [Array<Hash>] one range's worth of messages
        # @return [Array<Hash>] the content blocks that replace them
        def blocks(_messages)
          raise NotImplementedError, "strategy #{name} must implement #blocks(messages) -> Array<Hash>"
        end

        # Two strategies claiming disjoint stretches of one span, run as one --
        # {Composed}, and the operation this class declares a commutative monoid
        # at the foot of the file. Spelled `|` because what it does is take the
        # UNION of two range-sets, and because the partiality reads as a set
        # operation: an overlap refuses rather than picking a winner.
        def |(other) = Composed.new(self, other)

        # @param messages [Array<Hash>] one range's worth of messages
        # @param range [Range, nil] which sub-span they were sliced from.
        #   {Derivation}'s fold already holds it at the call site and passes it
        #   through; nil is "a slice nobody proposed", which is how every direct
        #   caller asks.
        # @return [Replacement] what replaces one range -- DROP if the collapse
        #   answers no blocks, since that is the unit of the monoid {#blocks}
        #   maps into rather than a blank replacement.
        def collapse(messages, range: nil) = Replacement.of(answered_blocks(messages, range))

        # The blocks for ONE proposed range, which is where composition enters.
        #
        # A strategy that proposed its own ranges answers its own {#blocks} and
        # never reads the range -- so this is invisible to every hook in the
        # tree, and {#blocks} keeps its one-argument shape, which it has to:
        # {Algebra::Elementwise} GENERATES {Elide}'s from a per-message map and
        # the generated method takes exactly one positional argument. Widening
        # the hook itself would mean widening that generator, one structure up,
        # for a parameter no elementwise map can use.
        #
        # {Composed} is the one strategy that overrides it, because a range it
        # answers was proposed by one of its two operands and only that operand
        # can collapse it. It is public so a composition can forward to the
        # operand that owns the range without reaching through its visibility.
        def blocks_for(messages, _range) = blocks(messages)

        # The strategies this one is made of: itself, for anything that is not a
        # composition. {Composed} is the only strategy that answers more, and
        # this is what lets it check that a range it is asked to collapse was
        # tagged by one of its own leaves rather than merely carrying a tag.
        def operands = [self]

        # Defined LAST, so Base's own definitions above are not refused by it,
        # and on the singleton so it fires for every subclass -- including one
        # written by `define_method`, which is the door `elementwise on: :collapse`
        # comes through.
        def self.method_added(name)
          super
          instead = SEALED[name]
          return if instead.nil?

          raise Sealed, "#{self} redefines ##{name}, which Strategy::Base defines once for every strategy " \
                        "so that a caller cannot reach an unvalidated answer; implement #{instead}"
        end

        private

        # `#blocks` is hand-written by some strategies and generated over a
        # hand-written per-element map by others, so a wrong shape is a mistake
        # that gets MADE -- and {Replacement}, which would catch it a moment
        # later, cannot name whose fault it is.
        def answered_blocks(messages, range)
          answered = blocks_for(messages, range)
          return answered if answered.is_a?(Array)

          raise NotBlocks, "strategy #{name} answered #{answered.inspect} from #blocks; " \
                           "expected an Array of content blocks"
        end

        # BELOW `#|`, which it names, and outside `private`, which a declaration
        # is not. It is also below `.method_added`, which it never reaches: that
        # hook fires for a `def`, and this is a class-level verb call.
        #
        # The unit is an INSTANCE of a subclass built after this class body
        # closes, which is exactly {Context::Combinator}'s situation with
        # {Context::Identity} and exactly what {Algebra.later} exists for.
        commutative_monoid on: :|, identity: Algebra.later { Identity.new }
      end
    end
  end
end
