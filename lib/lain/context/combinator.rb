# frozen_string_literal: true

module Lain
  class Context
    # A Context combinator: an endomorphism on the message list
    # (Array<Hash> -> Array<Hash>) that composes under `>>` into a monoid whose
    # unit is {Identity}.
    #
    # A class, not a module, because the algebra needs *values*: the unit
    # {Identity} is an INSTANCE you compose with, and {Composed} carries the two
    # stages it fused. A module has no instance to be the unit and no place to
    # hold that pair.
    #
    # A different composition from {Middleware}'s, which is a {Middleware::Stack}
    # of members each wrapping a downstream call (`#call(env, &app)`). A Context
    # combinator has no downstream to invoke -- it feeds the next stage's input
    # directly, Proc#>>'s shape -- so the two never compose with each other.
    class Combinator
      # @param messages [Array<Hash>]
      # @return [Array<Hash>] the identity: unchanged
      def call(messages)
        messages
      end

      # @return [Array<Symbol>] a subset of Provider::CAPABILITIES this
      #   combinator's strategy needs from a Provider. Empty for pure
      #   client-side transforms -- most of them, which inherit this default
      #   rather than restating it.
      def requires
        [].freeze
      end

      # Does this stage READ the list it is handed, or substitute one of its
      # own? A transform reads (this default); a stage that discards its
      # argument for a list it already holds -- a compacting turn's derived
      # chain -- overrides.
      #
      # It changes nothing about what a pipeline renders. What it buys is that
      # {Context#render} can skip PROJECTING a Timeline nothing downstream will
      # look at, and that walk is O(n) in history length on every turn of a
      # compacting session.
      #
      # @return [Boolean]
      def reads_messages?
        true
      end

      # `a >> b` runs `a`, then `b`. A fresh {Composed} rather than a mutation
      # -- Proc#>>'s idiom, which builds a new callable and rewrites neither
      # operand -- is what keeps `>>` associative and every combinator a frozen
      # value.
      def >>(other)
        Composed.new(self, other)
      end
    end
  end
end
