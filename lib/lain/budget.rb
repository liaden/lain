# frozen_string_literal: true

module Lain
  # What a run may spend and what it has: {Ceilings} a spawn attenuates, and
  # {Spent}, the monoid of what was used.
  #
  # Kept apart from the Agent because a budget stop and a `:refusal` are
  # different outcomes -- the harness ran out of rope, versus the model
  # declined. Conflating them costs a caller exactly the distinction it most
  # wants on an unbounded loop pointed at a shell.
  module Budget
    DEFAULT_ITERATIONS = 25

    # A ceiling was passed; `kind` names which one.
    class Exceeded < Error
      attr_reader :kind

      def initialize(message = "budget exceeded", kind: nil)
        @kind = kind
        super(message)
      end
    end

    # The ceilings for a run that bounds iterations and, optionally, tokens.
    def self.ceilings(iterations: DEFAULT_ITERATIONS, tokens: nil)
      Ceilings.new(iterations:, tokens:, dollars: nil, width: nil, depth: nil)
    end

    # What a run may spend against what it has. Iterations are not in {Spent},
    # so their count is handed to {#check_iterations!} by whoever keeps it.
    Account = Data.define(:ceilings, :spent) do
      # @param kind [Symbol] a {Ceilings} member
      # @return [Numeric, nil] the room left, nil where the kind is unlimited
      # @raise [ArgumentError] for iterations, which {Spent} does not hold
      def remaining(kind)
        raise ArgumentError, "iterations are counted per ask by the Agent, not spent" if kind == :iterations

        limit = ceilings.public_send(kind)
        limit && (limit - used(kind))
      end

      def exceeded?(kind) = remaining(kind)&.negative? || false

      # Checked before the iteration runs, so the ceiling counts iterations
      # performed, not attempted.
      # @raise [Lain::Budget::Exceeded] when `count` has reached the ceiling
      def check_iterations!(count)
        limit = ceilings.iterations
        return unless limit && count >= limit

        raise Exceeded.new("loop ran #{count} iterations, ceiling is #{limit}", kind: :iterations)
      end

      # Checked after each response: a turn's cost is only known once paid.
      # @raise [Lain::Budget::Exceeded] when the spend has passed the ceiling
      def check_tokens!
        return unless exceeded?(:tokens)

        raise Exceeded.new("spent #{spent.usage.total_tokens} tokens, ceiling is #{ceilings.tokens}", kind: :tokens)
      end

      private

      def used(kind)
        case kind
        when :tokens then spent.usage.total_tokens
        when :dollars then spent.dollars.amount
        else 0
        end
      end
    end
  end
end
