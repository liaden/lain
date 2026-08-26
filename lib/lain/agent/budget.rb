# frozen_string_literal: true

module Lain
  class Agent
    # The ceilings that bound an autonomous loop.
    #
    # Kept apart from the Agent because a budget stop and a `:refusal` are
    # different outcomes -- the harness ran out of rope, versus the model
    # declined. Conflating them costs a caller exactly the distinction it most
    # wants on an unbounded loop pointed at a shell.
    class Budget
      class Exceeded < Error; end

      DEFAULT_MAX_ITERATIONS = 25

      attr_reader :max_iterations, :max_total_tokens

      def initialize(max_iterations: DEFAULT_MAX_ITERATIONS, max_total_tokens: nil)
        @max_iterations = Integer(max_iterations)
        @max_total_tokens = max_total_tokens && Integer(max_total_tokens)
        freeze
      end

      # Checked before the iteration runs, so the ceiling counts iterations
      # performed, not attempted.
      def check_iterations!(iterations)
        return if iterations < max_iterations

        raise Exceeded, "loop ran #{iterations} iterations, ceiling is #{max_iterations}"
      end

      # Checked after each response: a turn's cost is only known once paid.
      def check_tokens!(usage)
        return unless max_total_tokens && usage.total_tokens > max_total_tokens

        raise Exceeded, "spent #{usage.total_tokens} tokens, ceiling is #{max_total_tokens}"
      end

      # The cooperative halt, grouped with the ceilings because all three are
      # the harness deciding to stop rather than a model outcome.
      #
      # `Async::Task#stop`, not `Thread#kill`, per docs/concurrency.md:
      # structured cancellation raises `Async::Stop` only at a
      # scheduler-controlled yield point, so `ensure` blocks run and the
      # immutable Timeline is only ever stopped BETWEEN whole commits. The task
      # is duck-typed as "responds to #stop"; Budget stays ignorant of async.
      def interrupt(task)
        task.stop
      end
    end
  end
end
