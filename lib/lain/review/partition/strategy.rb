# frozen_string_literal: true

module Lain
  module Review
    class Partition
      # The seam between a changeset and HOW IT IS GROUPED FOR READING. Grouping
      # by commit was the only answer for a long time and it read as the only
      # possible one; it is one strategy among several ({Whole}, {ByDirectory},
      # {ByCommit}), and this is what makes swapping it a decision rather than a
      # rewrite.
      #
      # Four messages, each a plain method a duck-typed strategy answers:
      #
      #   name                    how a scope spells this strategy
      #   partition(changeset)    -> [Partition], disjoint, covering every file
      #   advice                  the sentence a refusal recommends this by
      #   supports?(source)       whether this source can be grouped this way
      #
      # == A strategy takes a CHANGESET, never a source
      #
      # That is the seam, and it is what keeps a strategy testable without a
      # repository. {ByCommit} needs the walk, so a {Changeset} answers
      # `#commits` -- the strategy still takes the changeset. `#supports?` is
      # what a source that cannot answer for a strategy is refused BY, at
      # presentation, instead of dying on a missing message halfway through a
      # partition.
      #
      # == Why `check!` is a duck probe, not a base class
      #
      # {Review::Surface.check!}'s shape, deliberately reused rather than joined
      # by a third convention -- `surface.rb`'s own doc argues against inventing
      # one, and {CLI::CompactionStrategy#live_tier} is the other precedent. A
      # strategy is never required to subclass anything: {Whole} is nine lines
      # and would inherit machinery it does not need just to prove it belongs.
      #
      # The normalization below is Surface's, restated rather than called, for
      # two reasons that both hold: `review/partition` loads BEFORE
      # `review/surface` (a changeset partitions, so the value has to exist
      # first), and a partition strategy is not a surface -- borrowing a class
      # method across those two would couple the axes to make three lines
      # common. {MESSAGES} is the single place THIS port's shape is stated, and
      # that is the property that actually matters.
      module Strategy
        # A candidate strategy does not fully, publicly, and correctly answer
        # the port.
        class Incomplete < Error; end

        # The port's messages and each one's exact `Method#parameters` shape, in
        # the order the module doc lists them.
        #
        # Compared through {shape_of}, never `==` against this Hash directly:
        # what the port constrains is each argument's KIND and, for a keyword,
        # its NAME -- a keyword IS its name at every call site, while a
        # positional's is private to the method. The names below stay because
        # this Hash is also the port's documentation.
        #
        # DEEPLY frozen: `.freeze` on the outer Hash alone leaves the
        # `%i[req changeset]`-shaped inner Arrays mutable.
        MESSAGES = {
          name: [],
          partition: [%i[req changeset]],
          advice: [],
          supports?: [%i[req source]]
        }.transform_values { |shape| shape.map(&:freeze).freeze }.freeze

        # @param candidate [#name, #partition, #advice, #supports?]
        # @return [void]
        # @raise [Incomplete] naming what is wrong -- a message not answered at
        #   all, one answered only PRIVATELY, or one answered PUBLICLY with the
        #   wrong shape, in which case the ARITY it declares is named beside the
        #   one the port does. Kept apart rather than folded into one verdict:
        #   all three used to read as "you forgot to write this".
        def self.check!(candidate)
          absent, private_only, wrong_shape = sort_candidate(candidate)
          return if absent.empty? && private_only.empty? && wrong_shape.empty?

          raise Incomplete, incomplete_message(candidate, absent:, private_only:, wrong_shape:)
        end

        # What the port constrains about one message's arguments: every one's
        # KIND, and a keyword's NAME. Takes a `Method`/`UnboundMethod` or a
        # {MESSAGES} value, so both sides of every comparison are normalized by
        # the same code rather than by two readings of one rule.
        #
        # @return [Array<Array<Symbol>>]
        def self.shape_of(parameters)
          parameters = parameters.parameters if parameters.respond_to?(:parameters)
          parameters.map { |kind, name| kind == :keyreq ? [kind, name] : [kind] }
        end

        # @return [Array(Array<Symbol>, Array<Symbol>, Array<Array>)] messages
        #   `candidate` does not answer, answers only PRIVATELY, and answers
        #   publicly with the wrong shape -- the last paired with the shape it
        #   actually answered, because "wrong" without the number it is wrong by
        #   sends a reader back to the port to work out what was expected.
        def self.sort_candidate(candidate)
          MESSAGES.each_with_object([[], [], []]) do |(message, shape), (absent, private_only, wrong_shape)|
            if candidate.respond_to?(message)
              actual = shape_of(candidate.method(message))
              wrong_shape << [message, actual] unless actual == shape_of(shape)
            elsif candidate.respond_to?(message, true)
              private_only << message
            else
              absent << message
            end
          end
        end
        private_class_method :sort_candidate

        def self.incomplete_message(candidate, absent:, private_only:, wrong_shape:)
          clauses = [
            [absent, "does not answer %s"],
            [private_only, "answers %s only privately, never publicly"],
            [wrong_shape.map { |message, actual| miscounted(message, actual) }, "answers %s"]
          ].filter_map { |names, template| format(template, names.join(", ")) unless names.empty? }

          "#{candidate_name(candidate)} #{clauses.join("; ")}; a partition strategy must publicly answer " \
            "the full #{MESSAGES.keys.join(", ")} port, each with its documented shape"
        end
        private_class_method :incomplete_message

        def self.miscounted(message, actual)
          "#{message} with #{actual.size} argument(s) where the port declares #{MESSAGES.fetch(message).size}"
        end
        private_class_method :miscounted

        # `candidate.class.name` is nil for an anonymous class (every
        # `Class.new do ... end` test double), and `candidate.class` alone
        # prints a bare memory address that names nothing a reader can act on.
        def self.candidate_name(candidate) = candidate.class.name || "an anonymous class"
        private_class_method :candidate_name
      end
    end
  end
end
