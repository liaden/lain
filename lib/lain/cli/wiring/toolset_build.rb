# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What capabilities a run holds, and how a child inherits them --
      # {Wiring}'s "assemble a run's collaborators and hand off to the
      # frontend" minus the part that was never about assembly at all. The
      # tell was in the parameter lists: `(backend:, parent:, journal:)` was
      # threaded verbatim through three private methods, and a triple passed
      # identically at every call is state an object is missing, not
      # arguments. It is injected once, here, and the seam methods read it.
      #
      # The set is layered, and the layering is the policy. {BaseTools} is the
      # capability floor, and it is ALSO the union a child attenuates from --
      # so the same `base` is what {Skill::RoleSpawn} and {Tools::Subagent}
      # are handed, while `ask_human` and {Tools::RunSkill} are appended
      # AFTER, main-agent-only: a subagent must not be able to ask the human
      # directly, nor to render a skill scaffold back into a conversation that
      # is not the one the human is having.
      #
      # {#role_spawn} and {#auto_surface} are readable only once {#build} has
      # run, because they are things the build DISCOVERS rather than things it
      # is told -- Wiring delegates both, and its own callers (the Repl's
      # command surface) read them well after the toolset exists.
      class ToolsetBuild
        # The repl-phase role-spawn seam a `@role/skill` line folds through
        # (nil until {#build}), and the opt-in third approval surface over it
        # (nil without --auto-approve, so the Repl wires nothing extra by
        # default).
        attr_reader :role_spawn, :auto_surface

        # `provider:` is INJECTED rather than resolved here: it is the run's
        # spooled provider, and {Wiring} builds the only other one. Two
        # construction sites would be two answers to "which spool do round
        # trips tee into", and the pairing is not allowed to come apart.
        #
        # @param parent [#call] a thunk reading the live parent Timeline --
        #   the subagent tool reads the head at SPAWN time, so this must stay
        #   late-bound.
        def initialize(backend:, provider:, chronicle:, options:, supervisor:, parent:, journal:)
          @backend = backend
          @provider = provider
          @chronicle = chronicle
          @options = options
          @supervisor = supervisor
          @parent = parent
          @journal = journal
        end

        # The run's toolset: the capability floor, plus the child seams and
        # the two main-agent-only tools.
        #
        # @param recorder [Lain::Memory::Recorder] the ONE recorder backing
        #   the memory tools for the whole session
        # @param ask_human [Lain::Tools::AskHuman::Notifying] the reply seam
        #   {Wiring} wired, appended here rather than built here -- the Repl's
        #   replier fiber parks on the same object
        # @return [Lain::Toolset]
        def build(recorder, ask_human:)
          base = Lain::Toolset.new(BaseTools.build(recorder))
          @role_spawn = role_spawn_seam(base)
          @auto_surface = (Lain::Approval::AutoSurface.new(role_spawn: @role_spawn) if options[:auto_approve])
          Lain::Toolset.new(base.to_a + [research_subagent(base), ask_human, run_skill])
        end

        private

        attr_reader :backend, :chronicle, :options, :supervisor

        # One seam serves every role: the role, policy, and persona are chosen
        # PER CALL from the parsed role name and context mode, so what is
        # fixed here is only what they all share. `slots:` is the session's
        # rendered-persona source ({Backend#slots}, loaded once).
        def role_spawn_seam(base)
          Lain::Skill::RoleSpawn.new(toolset: base, slots: backend.slots, **child_seam_kwargs)
        end

        # The collaborators BOTH child seams attenuate over -- the same
        # spooled provider, child context, live parent handle, journal,
        # supervisor, and lineage observer. One method, so the sentence "over
        # the same seams" is code rather than a comment that can drift.
        def child_seam_kwargs
          { provider: @provider, context_factory: -> { backend.context },
            parent: @parent, journal: @journal, supervisor:, observer: chronicle.observer }
        end

        # The in-agent composition primitive: it renders a skill's scaffold
        # back to the SAME agent as a tool_result -- a continuation, not a
        # spawn. Built over the same catalog + slots the repl's ReplMiddleware
        # composes, loaded once from the project root.
        def run_skill = Lain::Tools::RunSkill.new(renderer: ReplMiddleware.renderer)

        # The chat default: an attenuated read-only child (schema posture,
        # depth 1). The observer routes its :spawn/:message lineage events
        # into the session record, exactly as ask_human's Q/A goes.
        def research_subagent(base)
          Lain::Tools::Subagent.new(toolset: base, policy: backend.spawn_policy(:researcher), max_depth: 1,
                                    **child_seam_kwargs)
        end
      end
    end
  end
end
