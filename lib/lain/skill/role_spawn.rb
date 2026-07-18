# frozen_string_literal: true

module Lain
  # Reopens the {Skill} value class (`Skill = Data.define`) to nest the
  # role-selecting spawn seam under it -- a `module Skill` would collide with the
  # Data class and raise, so this uses `class Skill`, the same reopen
  # {Skill::Invocation} uses.
  class Skill
    # The call-time role-selecting spawn seam: `(role_name, context_mode,
    # prompt) -> subagent result`. Where {Tools::Subagent} fixes its policy at
    # construction (the model cannot choose a role), this lets the CALLER pick a
    # role and a context mode PER CALL -- additive, not a change to the
    # model-facing tool, which stays construction-fixed.
    #
    # It holds the same collaborator set the exe's `research_subagent` assembles
    # (provider, a child-Context factory, the union to attenuate FROM, the live
    # parent handle, a journal, and -- for a future actor mode -- the
    # supervisor), plus the session {Prompt::Slots} the persona renders through.
    # None of these is role-specific: the role, its policy, and its persona are
    # all derived from `role_name` and `context_mode` at {#call} time.
    #
    # An unknown role fails loudly BEFORE any spawn ({Role::Catalog::Unknown}),
    # so a typo spends no tokens.
    class RoleSpawn
      # `observer` is forwarded verbatim into the spawned Subagent's Lineage
      # (T13): the child's :spawn/:message events must reach the session scribe
      # the exe wires, or -- once B3 drives `@role/skill` through this seam --
      # the child's lineage lands on the Null chain writer and vanishes from the
      # record ("silent record loss one level up", per {Tools::Subagent}). The
      # default MATCHES Subagent's own, so a caller that omits it is
      # byte-identical to spawning the tool directly.
      def initialize(provider:, context_factory:, toolset:, parent:, slots:,
                     journal: Channel::Null.instance, supervisor: Supervisor::Null,
                     observer: Event::ChainWriter::Null.new, max_depth: 1)
        @provider = provider
        @context_factory = context_factory
        @toolset = toolset
        @parent = parent
        @slots = slots
        @journal = journal
        @supervisor = supervisor
        @observer = observer
        @max_depth = max_depth
      end

      # Fetch the role (loud on unknown, before anything spawns), build a
      # one-shot Subagent under its policy and persona with the chosen prefix,
      # and run the prompt to a single final result. `context_mode` names the
      # prefix strategy directly (`:inherit` -> inherit the parent conversation,
      # `:fresh` -> a new root over the shared Store); an unknown mode fails
      # loudly through {Tool::SpawnPolicy::PrefixStrategy}, the same posture the
      # catalog takes toward an unknown role.
      def call(role_name, context_mode, prompt)
        build_subagent(Role::Catalog.fetch(role_name), context_mode).run(prompt)
      end

      private

      def build_subagent(role, context_mode)
        Tools::Subagent.new(
          provider: @provider, context_factory: @context_factory, toolset: @toolset,
          policy: role.spawn_policy(prefix: context_mode), parent: @parent,
          persona: Role::Persona.new(role:, slots: @slots),
          journal: @journal, supervisor: @supervisor, observer: @observer,
          max_depth: @max_depth, name: role.name.to_s
        )
      end
    end
  end
end
