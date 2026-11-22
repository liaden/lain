# frozen_string_literal: true

module Lain
  module Middleware
    # Hands a tool the real home path, account and host where the model wrote
    # their placeholders. The model only ever sees those placeholders, since
    # {Provider::HTTP::EgressGuard} aliases every request body, so the paths
    # and file contents it writes back carry them. Every string leaf of the
    # input is restored, however deeply an input nests its strings.
    #
    # Only the call is restored, never the model's turn: the turn is the
    # model's own text, and rewriting it would move its digest.
    class RestoreIdentity < Base
      # Every placeholder opens with it, so a string without it is left unread.
      MARK = "<lain:"

      # @param identity [#restore] the run's {Sensitivity::Secrets::Identity}
      def initialize(identity:)
        @identity = identity
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        restored = restored_effect(effect)
        downstream(restored.equal?(effect) ? env : env.merge(effect: restored), &app)
      end

      private

      def restored_effect(effect)
        return approval(effect) if effect.approval?

        input = restored(effect.input)
        input == effect.input ? effect : effect.with(input:)
      end

      def approval(effect)
        inner = restored_effect(effect.effect)
        inner.equal?(effect.effect) ? effect : Effect::Approval.new(effect: inner)
      end

      def restored(value)
        case value
        when Hash then value.transform_values { restored(_1) }
        when Array then value.map { restored(_1) }
        when String then value.include?(MARK) ? @identity.restore(value) : value
        else value
        end
      end
    end
  end
end
