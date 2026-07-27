# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # An answer to {Base#propose_ranges} that is not an interval partition of
      # the span it was asked about. Loud, and named for what it is not: the
      # conditions it enforces are well-formedness, not style.
      class NotAPartition < Error; end

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
      #   ranges(messages, span:) -> Array<Range>   # the proposal, validated
      #   collapse(messages)      -> Replacement    # the blocks, wrapped
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
        # What a subclass may not redefine, and what to write instead. The hint
        # is half the value: the mistake this catches is a reasonable one, made
        # by someone who read the card's duck section and not this file.
        SEALED = { ranges: "#propose_ranges, which #ranges validates",
                   collapse: "#blocks, or `elementwise on: :blocks`" }.freeze

        # The name this strategy answers to in errors and in the journalled
        # derivation edge. Interned, because an anonymous class's `to_s` is a
        # freshly built MUTABLE String (CLAUDE.md's named trap) and this name is
        # reachable from values that have to stay shareable.
        def name = -(self.class.name || self.class.to_s)

        # @param messages [Array<Hash>] the rendered messages
        # @param span [Range] the droppable span, as message indices
        # @return [Array<Range>] the sub-spans to collapse: ascending,
        #   non-overlapping, all inside `span`. Empty means "collapse nothing",
        #   which is how a strategy declines a turn.
        def ranges(messages, span:)
          Partition.new(strategy: name, span:, ranges: propose_ranges(messages, span:)).validated
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

        # @return [Replacement] what replaces one range -- DROP if the collapse
        #   answers no blocks, since that is the unit of the monoid {#blocks}
        #   maps into rather than a blank replacement.
        def collapse(messages) = Replacement.of(answered_blocks(messages))

        # The conditions of an interval partition, and the only place they are
        # stated. Order matters three times over: a non-collection cannot be
        # asked for its elements at all, a non-Range cannot be asked whether it
        # is empty, and ranges out of order would ALSO trip the overlap check,
        # so being told about an overlap when the real fault is the ordering
        # sends a reader to the wrong line. Each refusal is stated on its own
        # terms so that the message names the fault a reader has to fix, rather
        # than whichever later check happened to trip over it first.
        Partition = Data.define(:strategy, :span, :ranges) do
          def validated
            refuse_answerless
            refuse_foreign
            refuse_uncountable
            refuse_empty
            refuse_outside
            refuse_disorder
            refuse_overlap
            ranges
          end

          private

          # FIRST, because everything below asks the proposal a question only a
          # collection can answer. A strategy whose hook falls off the end (a
          # guard clause with no else, an `each` where a `map` was meant)
          # answers `nil`, and `nil.grep_v` named nobody -- a NoMethodError from
          # inside the validator, about the validator, for a bug in a strategy.
          def refuse_answerless
            return if ranges.is_a?(Array)

            raise NotAPartition, "#{strategy} answers #{ranges.inspect} from #propose_ranges; expected an " \
                                 "Array of Ranges"
          end

          def refuse_foreign
            alien = ranges.grep_v(Range)
            return if alien.empty?

            raise NotAPartition, "#{strategy} answers #{listed(alien)}, which is not a Range"
          end

          # A range's members ARE message indices -- the caller maps them onto
          # source turns -- so a Range of anything but Integers is not a smaller
          # kind of partition, it is a different type of thing. `0.0..1.5` cleared
          # every check below it (`cover?` compares numerically, and it is
          # neither empty nor out of order) and died in the CALLER as
          # `TypeError: can't iterate from Float`, naming nobody. Unbounded ends
          # are left to #refuse_outside, which has something truer to say about
          # them.
          def refuse_uncountable
            odd = ranges.select { |range| bounded?(range) && !integral?(range) }
            return if odd.empty?

            raise NotAPartition, "#{strategy} answers #{listed(odd)}, whose endpoints are not Integer message " \
                                 "indices"
          end

          def bounded?(range) = !range.begin.nil? && !range.end.nil?

          def integral?(range) = range.begin.is_a?(Integer) && range.end.is_a?(Integer)

          # An empty interval is not a small collapse, it is no collapse, and
          # answering one is how a strategy would commit a replacement event that
          # subsumes nothing. Refused on its own terms rather than through
          # #cover?, which reports `2..1` as "outside 0..3" -- true of nothing,
          # and it sends the reader looking for a bounds bug.
          def refuse_empty
            hollow = ranges.select { |range| hollow?(range) }
            return if hollow.empty?

            raise NotAPartition, "#{strategy} answers #{listed(hollow)}, an empty range; a range that " \
                                 "collapses nothing is spelled by leaving it out"
          end

          def refuse_outside
            stray = ranges.reject { |range| span.cover?(range) }
            return if stray.empty?

            raise NotAPartition, "#{strategy} answers #{listed(stray)}, outside the span it was asked " \
                                 "about, #{span.inspect}"
          end

          def refuse_disorder
            pair = ranges.each_cons(2).find { |before, after| before.first > after.first }
            return if pair.nil?

            raise NotAPartition, "#{strategy} answers #{pair.last.inspect} after #{pair.first.inspect}, " \
                                 "so its ranges are not in ascending order"
          end

          def refuse_overlap
            pair = ranges.each_cons(2).find { |before, after| before.cover?(after.first) }
            return if pair.nil?

            raise NotAPartition, "#{strategy} answers #{pair.first.inspect} and #{pair.last.inspect}, " \
                                 "which overlap at #{pair.last.first}"
          end

          # Bounded at both ends and covering nothing. An unbounded range is left
          # to #refuse_outside, which is the check that has something true to say
          # about it.
          def hollow?(range)
            return false if range.begin.nil? || range.end.nil?

            range.exclude_end? ? range.begin >= range.end : range.begin > range.end
          end

          def listed(ranges) = ranges.map(&:inspect).join(", ")
        end
        private_constant :Partition

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
        def answered_blocks(messages)
          answered = blocks(messages)
          return answered if answered.is_a?(Array)

          raise NotBlocks, "strategy #{name} answered #{answered.inspect} from #blocks; " \
                           "expected an Array of content blocks"
        end
      end
    end
  end
end
