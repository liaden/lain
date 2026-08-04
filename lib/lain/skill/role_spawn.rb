# frozen_string_literal: true

module Lain
  class Skill
    # Reopens the {Skill} value class (`Skill = Data.define`) to nest the
    # role-selecting spawn seam under it -- a `module Skill` would collide with the
    # Data class and raise, so this uses `class Skill`, the same reopen
    # {Skill::Invocation} uses.

    # The call-time role-selecting spawn seam: `(role_name, context_mode,
    # prompt) -> subagent result`. Where {Tools::Subagent} fixes its policy at
    # construction (the model cannot choose a role), this lets the CALLER pick a
    # role and a context mode PER CALL -- additive, not a change to the
    # model-facing tool, which stays construction-fixed.
    #
    # It holds the SAME collaborator set the exe's `research_subagent` assembles
    # -- one {Tools::Subagent::Seam} -- plus the union to attenuate FROM and the
    # session {Prompt::Slots} the persona renders through. None of these is
    # role-specific: the role, its policy, and its persona are all derived from
    # `role_name` and `context_mode` at {#call} time, which is why the seam is
    # held once here and the per-call work is role selection only.
    #
    # An unknown role fails loudly BEFORE any spawn ({Role::Catalog::Unknown}),
    # so a typo spends no tokens.
    class RoleSpawn
      # The seam this instance spawns every role over. Public because the study
      # bench asks which provider and journal a role's children ran against, and
      # because the wiring's own spec asserts that this seam and the chat
      # subagent's are the SAME object.
      attr_reader :seam

      # `toolset` and `slots` stay their own keywords rather than joining the
      # seam: each adopter attenuates over a different base union, and `slots` is
      # the persona source that {Tools::Subagent} -- which the seam is shaped for
      # -- has no use for.
      #
      # The seam's `observer` is forwarded verbatim into the spawned Subagent's
      # Lineage (T13): the child's :spawn/:message events must reach the session
      # scribe the exe wires, or -- once B3 drives `@role/skill` through this seam
      # -- the child's lineage lands on the Null chain writer and vanishes from
      # the record ("silent record loss one level up", per {Tools::Subagent}).
      # The Null defaults live on the Seam and MATCH Subagent's own, so a caller
      # that omits them is byte-identical to spawning the tool directly.
      #
      # The loose collaborator keywords this took before the Seam existed still
      # work -- they land in `**spawn_over` and {Seam.resolve} builds the same
      # value; passing a seam AND its members raises.
      def initialize(toolset:, slots:, seam: nil, max_depth: 1, **spawn_over)
        @seam = Tools::Subagent::Seam.resolve(seam, **spawn_over)
        @toolset = toolset
        @slots = slots
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

      # Everything role-derived, and nothing else: the policy, the persona, and
      # the child's name. The seam, the union, and the ceiling are what this
      # instance already held.
      def build_subagent(role, context_mode)
        Tools::Subagent.new(
          seam: @seam, toolset: @toolset, policy: role.spawn_policy(prefix: context_mode),
          persona: Role::Persona.new(role:, slots: @slots),
          max_depth: @max_depth, name: role.name.to_s
        )
      end
    end
  end
end
