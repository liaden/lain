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
    # A SEPARATE algebra from Middleware::Composable despite the shared `>>` and
    # monoid shape. A Middleware wraps a downstream call (`#call(env, &app)`); a
    # Context combinator has no downstream to invoke -- it feeds the next
    # stage's input directly, Proc#>>'s shape. Reusing Composable would force
    # every combinator to accept a block it can never meaningfully call, and
    # would let a combinator and a Middleware compose with each other into
    # nonsense. The laws are still shared, through the "a monoid" property
    # group; only the shape differs.
    class Combinator
      include Algebra::Monoid

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

      # {Identity} is an instance built after this class body closes, so the
      # unit can only be named lazily.
      monoid on: :>>, identity: Algebra.later { Context::Identity }
    end

    # The monoid unit: composing it changes nothing, so a fold over an empty
    # combinator list (or an optional combinator slot) stays total instead of
    # special-casing nil. An INSTANCE, not a class, because the unit of a monoid
    # is a value you compose with -- the whole reason {Combinator} is
    # instantiable.
    Identity = Combinator.new.freeze

    # Associativity falls out of this being plain function composition:
    # however you group the `>>`s, the resulting call order is the same, so
    # there is only one behavior to observe.
    class Composed < Combinator
      def initialize(first, second)
        super()
        @first = first
        @second = second
        freeze
      end

      def call(messages)
        @second.call(@first.call(messages))
      end

      # The union: a composed pipeline needs whatever either stage needs.
      def requires
        (@first.requires | @second.requires).freeze
      end

      # The FIRST stage alone decides, unlike #requires: `second` is handed
      # `first`'s output and can never see the list this composition was
      # called with, so a substituting stage blinds everything behind it. The
      # converse is what makes the union wrong here -- a reading stage in
      # front of a substituting one still reads.
      def reads_messages?
        @first.reads_messages?
      end
    end
  end
end
