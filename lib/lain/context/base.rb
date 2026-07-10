# frozen_string_literal: true

module Lain
  class Context
    # A Context combinator: an endomorphism on the message list,
    # Array<Hash> -> Array<Hash>, composable under `>>` into a monoid.
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
    class Base
      # @param messages [Array<Hash>]
      # @return [Array<Hash>] the identity: unchanged
      def call(messages)
        messages
      end

      # @return [Array<Symbol>] a subset of Provider::CAPABILITIES this
      #   combinator's strategy needs from a Provider. Empty for pure
      #   client-side transforms -- most of them.
      def requires
        [].freeze
      end

      # `a >> b` composes into a combinator that runs `a`, then `b`.
      def >>(other)
        Composed.new(self, other)
      end
    end

    # The monoid unit: composing it changes nothing, so a fold over an empty
    # combinator list (or an optional combinator slot) stays total instead of
    # special-casing nil -- the same role Middleware::Identity plays there.
    Identity = Base.new

    # Two combinators fused into one: `first` runs, then `second` runs on
    # its output. Associativity falls out of this being plain function
    # composition -- however you group the `>>`s, the resulting call order
    # is the same, so there is only one behavior to observe.
    class Composed < Base
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
