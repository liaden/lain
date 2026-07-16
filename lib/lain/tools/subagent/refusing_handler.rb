# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # The refusal record journaled when a `handler_union` child names a tool it
      # was not attenuated to. A tiny Journalable so the refusal is an attributed
      # event in the record, not a swallowed decision (`refused` is its wire tag).
      Refused = Data.define(:tool_use_id, :name) do
        include Telemetry::Journalable
      end

      # The Handler arm of the `handler_union` posture: the child renders the
      # SHARED UNION (sibling spawns render byte-identical tools blocks -- the
      # CE-4 win; the union need not equal the spawning parent's own toolset),
      # but this decorator refuses -- as an is_error {Tool::Result}, and
      # journaled -- any tool_call the child was not attenuated to, delegating
      # every permitted call inward to the real executor. Enforcement was always
      # the Handler's job (tools are capabilities), so attenuation over a union
      # schema is honest: the model may ATTEMPT a disallowed tool and be told no.
      #
      # Its own file (the {Effect::Handler::Gate} shape) because it is a distinct
      # responsibility from the spawn tool: this enforces, {Subagent} runs.
      class RefusingHandler < Effect::Handler
        def initialize(allowed:, journal:, inner:)
          super(inner:)
          @allowed = allowed
          @journal = journal
        end

        # It handles exactly the calls it must BLOCK; everything else -- permitted
        # tool calls, approvals -- falls through to `inner`.
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
