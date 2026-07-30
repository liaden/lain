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
      # T23 took the argument one step further, where it had always pointed: the
      # six a child spawn is built over used to be assembled into a Hash by a
      # private `#child_seam_kwargs` and splatted into both child seams. They are
      # now one {Lain::Tools::Subagent::Seam}, built in the constructor, which is
      # why five of this class's ivars are gone -- provider, chronicle,
      # supervisor, journal, and the parent handle were only ever held to fill
      # that Hash.
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
        # trips tee into", and the pairing is not allowed to come apart. It, the
        # chronicle's observer, the supervisor, the journal and the parent handle
        # are read once, into the one spawn {Lain::Tools::Subagent::Seam} both
        # child seams travel over.
        #
        # `library:` is injected for the same reason and is REQUIRED, not
        # defaulted: the run has ONE {Skill::Library}, and a default here would
        # be a second read of the same tree that nothing would ever notice
        # disagreeing with /help's. It arrived as a `catalog:` keyword beside a
        # `backend.slots` reach-through until T40 named the pair -- one keyword
        # cannot be half-forgotten, which two could.
        #
        # @param parent [#call] a thunk reading the live parent Timeline --
        #   the subagent tool reads the head at SPAWN time, so this must stay
        #   late-bound.
        def initialize(backend:, provider:, chronicle:, options:, supervisor:, parent:, journal:, library:)
          @library = library
          @backend = backend
          @options = options
          @seam = Lain::Tools::Subagent::Seam.new(
            provider:, context_factory: -> { backend.context }, parent:,
            journal:, supervisor:, observer: chronicle.observer
          )
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

        attr_reader :backend, :library, :options, :seam

        # One seam serves every role: the role, policy, and persona are chosen
        # PER CALL from the parsed role name and context mode, so what is
        # fixed here is only what they all share. `slots:` is the session's
        # rendered-persona source -- the library's half, loaded once.
        def role_spawn_seam(base)
          Lain::Skill::RoleSpawn.new(seam:, toolset: base, slots: library.slots)
        end

        # The in-agent composition primitive: it renders a skill's scaffold
        # back to the SAME agent as a tool_result -- a continuation, not a
        # spawn. Built off the run's ONE library, so it and the repl's
        # ReplMiddleware compose the same pair #role_spawn_seam frames children
        # with. It called `ReplMiddleware.renderer` argument-less until T15,
        # which read the project tree twice more -- a claim of "loaded once"
        # that the loads did not keep; the shared composition seam that fixed
        # then lives on the library now ({Skill::Library#renderer}).
        def run_skill = Lain::Tools::RunSkill.new(renderer: library.renderer)

        # The chat default: an attenuated read-only child (schema posture,
        # depth 1). The observer routes its :spawn/:message lineage events
        # into the session record, exactly as ask_human's Q/A goes.
        def research_subagent(base)
          Lain::Tools::Subagent.new(seam:, toolset: base, policy: backend.spawn_policy(:researcher), max_depth: 1)
        end
      end
    end
  end
end
