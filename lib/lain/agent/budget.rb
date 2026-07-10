# frozen_string_literal: true

require_relative "../error"
require_relative "../usage"

module Lain
  class Agent
    # The ceilings that bound an autonomous loop.
    #
    # Kept apart from the Agent because they answer a different question. A
    # `:refusal` is the *model's* outcome, recorded and inspected. A budget stop
    # is the *harness* deciding to halt, and it raises. Conflating the two would
    # make "the model declined" and "we ran out of rope" indistinguishable to a
    # caller, which matters most in exactly the situation you least want
    # ambiguity: an unbounded loop pointed at a shell.
    class Budget
      class Exceeded < Error; end

      DEFAULT_MAX_ITERATIONS = 25

      attr_reader :max_iterations, :max_total_tokens

      def initialize(max_iterations: DEFAULT_MAX_ITERATIONS, max_total_tokens: nil)
        @max_iterations = Integer(max_iterations)
        @max_total_tokens = max_total_tokens && Integer(max_total_tokens)
        freeze
      end

      # Correctness gate 7, first half. Checked before the iteration runs, so the
      # ceiling is the number of iterations performed, not attempted.
      def check_iterations!(iterations)
        return if iterations < max_iterations

        raise Exceeded, "loop ran #{iterations} iterations, ceiling is #{max_iterations}"
      end

      # Second half. Checked after each response, because the cost of a turn is
      # only known once it has been paid.
      def check_tokens!(usage)
        return unless max_total_tokens && usage.total_tokens > max_total_tokens

        raise Exceeded, "spent #{usage.total_tokens} tokens, ceiling is #{max_total_tokens}"
      end
    end
  end
end
