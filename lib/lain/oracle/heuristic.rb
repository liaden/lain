# frozen_string_literal: true

module Lain
  module Oracle
    # The model-free tier: a pure predicate decides the answer locally, validated
    # through the SAME schema as the model tier and returned as the SAME Promise,
    # so a caller cannot tell which tier answered. No provider is wired -- #ask is
    # the whole computation. Mirrors the Null-Object second-arm shape of
    # {Middleware::RefuseSecretWrites::NullOracle}: one swappable arm over one
    # interface, here decided without a model call.
    class Heuristic
      # @param definition [Oracle::Definition] owns the schema the answer is
      #   validated against
      # @param predicate [#call] `inputs Hash -> answer attributes Hash`
      def initialize(definition:, predicate:)
        @definition = definition
        @predicate = predicate
      end

      def ask(inputs = {})
        @definition.answer(@predicate.call(inputs))
      end
    end
  end
end
