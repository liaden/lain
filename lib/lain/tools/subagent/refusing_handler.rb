# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # A tiny Journalable, so a refusal is an attributed event in the record
      # rather than a swallowed decision.
      Refused = Data.define(:tool_use_id, :name) do
        include Telemetry::Journalable
      end

      # The Handler arm of the `handler_union` posture: the child renders the
      # SHARED UNION -- sibling spawns render byte-identical tools blocks, which
      # is the cache win -- and this decorator refuses, as an is_error
      # {Tool::Result} and journaled, any tool_call the child was not attenuated
      # to. Enforcement was always the Handler's job, since tools are
      # capabilities, so attenuation over a union schema is honest: the model
      # may ATTEMPT a disallowed tool and be told no.
      class RefusingHandler < Effect::Handler
        def initialize(allowed:, journal:, inner:)
          super(inner:)
          @allowed = allowed
          @journal = journal
        end

        # It handles exactly the calls it must BLOCK; everything else falls
        # through to `inner`.
        def handles?(effect)
          effect.tool_call? && !@allowed.include?(effect.name)
        end

        def tool_named(name) = @inner&.tool_named(name)

        protected

        def perform(effect, _context)
          @journal << Refused.new(tool_use_id: effect.tool_use_id, name: effect.name)
          Tool::Result.error("subagent is not permitted to call #{effect.name.inspect}")
        end
      end
    end
  end
end
