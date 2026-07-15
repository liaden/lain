# frozen_string_literal: true

module Lain
  class Context
    # A Context combinator: an endomorphism on the message list
    # (Array<Hash> -> Array<Hash>) that composes under `>>` into a monoid whose
    # unit is {Identity}. That one sentence IS the algebra; everything below is
    # why it is a class and not something lighter.
    #
    # A class, not a module or an ActiveSupport::Concern, because the algebra
    # needs *values*, not just shared behavior: the unit {Identity} is an
    # INSTANCE (you compose with it, `combinator >> Identity`), and {Composed}
    # carries STATE (the two stages it fused). A module has no instance to be
    # the unit and no place to hold that pair; mixing one in would still leave
    # every combinator needing its own class to be instantiable. So the base of
    # the algebra is itself an instantiable class, and its bare instance is the
    # Null-Object identity -- the same move Middleware makes with its own unit.
    #
    # This is a SEPARATE algebra from Middleware::Composable, not a reuse of
    # it, despite the shared `>>` name and monoid shape. Middleware wraps a
    # downstream call (`#call(env, &app)`) -- composition means nesting
    # around an eventual invocation, and the identity is a pass-through of
    # that call. A Context combinator has no downstream to invoke: it is one
    # pure pipeline stage feeding the next stage's input directly, exactly
    # the shape of Ruby's own Proc#>> (`(f >> g).call(x) == g.call(f.call(x))`).
    # Reusing Middleware::Composable would force every combinator to accept a
    # block it can never meaningfully call, and would let a Context
    # combinator and a Middleware compose with each other and silently
    # produce nonsense -- keeping the types separate is a feature, not
    # duplication, since the *laws* (both a monoid, both property-tested via
    # the shared "a monoid" group) are still shared, only the shape differs.
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

      # `a >> b` composes into a combinator that runs `a`, then `b`. Returning
      # a fresh {Composed} rather than mutating is exactly Ruby's own Proc#>>
      # idiom -- composition builds a new callable, it never rewrites either
      # operand -- which is what keeps `>>` associative and every combinator a
      # frozen value.
      def >>(other)
        Composed.new(self, other)
      end
    end

    # The monoid unit: composing it changes nothing, so a fold over an empty
    # combinator list (or an optional combinator slot) stays total instead of
    # special-casing nil -- the same role Middleware::Identity plays there. It
    # is an INSTANCE, not a class, because the unit of a monoid is a value you
    # compose with, which is the whole reason {Combinator} is instantiable.
    # Frozen like {Composed}, so the unit is a deeply-frozen, Ractor-shareable
    # value too -- the base carries no mutable state, so there is nothing to lose.
    Identity = Combinator.new.freeze

    # Two combinators fused into one: `first` runs, then `second` runs on
    # its output. Associativity falls out of this being plain function
    # composition -- however you group the `>>`s, the resulting call order
    # is the same, so there is only one behavior to observe.
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
    end
  end
end
