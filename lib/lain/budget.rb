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

    # Finite so an actor pair cannot chatter forever; a role that needs more asks for it.
    DEFAULT_MESSAGES = 64

    # What a skill's line is allowed, read when the skill starts. The issue
    # count is a thunk because the epic's graph changes between lines.
    class Allowance
      # @param table [Table]
      # @param issues [#call] the mounted epic's issue count right now
      def initialize(table:, issues: -> { 0 })
        @table = table
        @issues = issues
        freeze
      end

      # @param skill [String, nil] the skill the line invokes; nil for a plain line
      # @return [Hash{Symbol => Integer}] `{iterations:}`: the skill's row, else the default row
      def grant(skill = nil)
        { iterations: @table.iterations(skill:, issues: @table.named?(skill) ? @issues.call : 0) }
      end

      # Grants nothing, so a line keeps its agent's own ceiling.
      NONE = Class.new { def grant(_skill = nil) = {} }.new.freeze
    end

    # A ceiling was passed; `kind` names which one.
    class Exceeded < Error
      attr_reader :kind

      def initialize(message = "budget exceeded", kind: nil)
        @kind = kind
        super(message)
      end
    end

    # The ceilings for a run that bounds iterations and messages and, optionally, tokens.
    def self.ceilings(iterations: DEFAULT_ITERATIONS, tokens: nil, messages: DEFAULT_MESSAGES)
      Ceilings.new(iterations:, tokens:, dollars: nil, width: nil, depth: nil, messages:)
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

      # @return [Ceilings] what is left to grant: the ceilings less this ask's
      #   iterations, the spend, and the tokens a live child holds
      def room(iterations_used:, reserved:)
        ceilings.with(iterations: ceilings.iterations&.-(iterations_used),
                      tokens: remaining(:tokens)&.-(reserved), dollars: remaining(:dollars))
      end

      # Checked before the iteration runs, so the ceiling counts iterations
      # performed, not attempted.
      # @raise [Lain::Budget::Exceeded] when `count` has reached the ceiling
      def check_iterations!(count)
        limit = ceilings.iterations
        return unless limit && count >= limit

        raise Exceeded.new("loop ran #{count} iterations, ceiling is #{limit}", kind: :iterations)
      end

      # Checked before each call: a ceiling met exactly leaves nothing to pay
      # the next call with.
      # @raise [Lain::Budget::Exceeded] when `count` has reached the iteration
      #   ceiling, or no tokens or dollars are left
      def check_step!(count)
        check_iterations!(count)
        left = remaining(:tokens)
        raise Exceeded.new(spent_tokens, kind: :tokens) if left && !left.positive?

        dollars_left = remaining(:dollars)
        raise ceilings.dollars_refusal(spent) if dollars_left && !dollars_left.positive?
      end

      # Checked after each response: a turn's cost is only known once paid.
      # @raise [Lain::Budget::Exceeded] when the spend has passed the ceiling
      def check_tokens!
        return unless exceeded?(:tokens)

        raise Exceeded.new(spent_tokens, kind: :tokens)
      end

      private

      def spent_tokens = "spent #{spent.usage.total_tokens} tokens, ceiling is #{ceilings.tokens}"

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
