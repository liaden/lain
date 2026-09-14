# frozen_string_literal: true

module Lain
  module Middleware
    # The refusal the `handler_union` spawn posture runs a child behind. The
    # child renders the SHARED UNION -- sibling spawns render byte-identical
    # tools blocks, which is the cache win -- and this layer refuses, as an
    # is_error {Tool::Result} and journaled, any tool call the child was not
    # attenuated to. Enforcement was always the tool phase's job, since tools
    # are capabilities, so attenuation over a union schema is honest: the model
    # may ATTEMPT a disallowed tool and be told no.
    #
    # It sits OUTSIDE the child's {Sensitivity} and {Gate}: a call the child
    # was never attenuated to is refused outright, not parked for a human who
    # would then watch it be refused anyway.
    class RefuseUnpermitted < Base
      # A tiny Journalable, so a refusal is an attributed event in the record
      # rather than a swallowed decision.
      Refused = Data.define(:tool_use_id, :name) do
        include Telemetry::Journalable
      end

      # @param allowed [Array<String>] the tool names the child was attenuated to
      # @param journal [#<<] where {Refused} lands
      def initialize(allowed:, journal:)
        @allowed = allowed.map(&:to_s).freeze
        @journal = journal
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        return downstream(env, &app) unless unpermitted?(effect)

        @journal << Refused.new(tool_use_id: effect.tool_use_id, name: effect.name)
        env.merge(result: Tool::Result.error("subagent is not permitted to call #{effect.name.inspect}"))
      end

      private

      def unpermitted?(effect) = effect.tool_call? && !@allowed.include?(effect.name)
    end
  end
end
