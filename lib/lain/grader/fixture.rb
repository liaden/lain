# frozen_string_literal: true

module Lain
  module Grader
    # A deterministic task: a named bundle of HARD assertions over a subject,
    # scored with no model in the loop. Each `check` is a description paired with
    # a predicate; the {Grade}'s score is the fraction of predicates that held,
    # and it passes only when all did. Because every predicate is a pure function
    # of the subject, the same subject always scores the same Grade -- the
    # property that lets speculative branching argmax over a fixture and Compare
    # treat its score as a real metric rather than noise.
    #
    #   Fixture.new("byte-stable replay") do |f|
    #     f.check("two model calls") { |dr| dr.steps == 2 }
    #     f.check("identical bytes")  { |dr| dr.diff(ctx).identical? }
    #   end.grade(dry_replay)
    #
    # The builder is YIELDED, not `instance_eval`d: a predicate block must keep
    # the caller's `self` so it can close over the caller's own helpers (a spec's
    # `let`, a task's method). `instance_eval` would silently rebind `self` to the
    # builder and turn those references into NoMethodErrors.
    class Fixture
      # A single hard assertion: what it claims, and the predicate that checks it.
      Criterion = Data.define(:description, :predicate)

      attr_reader :name, :criteria

      # @param name [String] what this task is
      # @yield the criteria-declaring block, evaluated against a builder
      def initialize(name, &block)
        @name = -name.to_s
        @criteria = Builder.build(&block).freeze
        freeze
      end

      # @param subject the thing under test (a DryReplay, a run, anything)
      # @return [Grade] score = fraction met; passes iff every criterion held
      def grade(subject)
        outcomes = @criteria.map { |criterion| [criterion, evaluate(criterion, subject)] }
        met = outcomes.count { |(_criterion, reason)| reason.nil? }
        Grade.new(score: met.fdiv(@criteria.size), pass: met == @criteria.size, why: explain(outcomes))
      end

      private

      # nil when the criterion held; otherwise the reason it did not. A predicate
      # that RAISES is a failed check whose reason is the exception, not a crash
      # -- a grader that dies on one bad criterion is less useful than one that
      # reports it, and the failure is still LOUD (it lands in `#why`).
      def evaluate(criterion, subject)
        criterion.predicate.call(subject) ? nil : "did not hold"
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end

      def explain(outcomes)
        lines = outcomes.map do |(criterion, reason)|
          reason.nil? ? "PASS #{criterion.description}" : "FAIL #{criterion.description} (#{reason})"
        end
        "#{@name}: #{lines.join("; ")}"
      end

      # Collects `check` declarations from the block into Criteria. A separate
      # object so the block cannot see or disturb the Fixture's own state -- it
      # only speaks `check`.
      class Builder
        def self.build
          builder = new
          yield builder if block_given?
          builder.criteria
        end

        attr_reader :criteria

        def initialize
          @criteria = []
        end

        def check(description, &predicate)
          raise ArgumentError, "check #{description.inspect} needs a predicate block" unless predicate

          @criteria << Criterion.new(description: -description.to_s, predicate: predicate)
        end
      end
    end
  end
end
