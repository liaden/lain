# frozen_string_literal: true

module Lain
  class Skill
    # Reopens the {Skill} value class (`Skill = Data.define`): a `module Skill`
    # would collide with the Data class and raise, so this uses `class Skill`,
    # the same reopen {Skill::Invocation} uses.

    # The call-time role-selecting spawn seam: `(role_name, context_mode,
    # prompt) -> subagent result`. Where {Tools::Subagent} fixes its policy at
    # construction (the model cannot choose a role), this lets the CALLER pick a
    # role and a context mode PER CALL -- additive, not a change to the
    # model-facing tool, which stays construction-fixed.
    #
    # None of its collaborators is role-specific: the role, its policy and its
    # persona all derive from `role_name` and `context_mode` at {#call} time, so
    # the seam is held once and the per-call work is role selection only. An
    # unknown role fails loudly BEFORE any spawn, so a typo spends no tokens.
    class RoleSpawn
      # Public because the study bench asks which provider and journal a role's
      # children ran against, and because the wiring's own spec asserts that this
      # seam and the chat subagent's are the SAME object.
      attr_reader :seam

      # `toolset` and `slots` stay their own keywords rather than joining the
      # seam: each adopter attenuates over a different base union, and `slots`
      # is the persona source the seam's shape has no use for.
      #
      # The seam's `observer` is forwarded verbatim into the spawned Subagent's
      # Lineage: the child's :spawn/:message events must reach the session
      # scribe the exe wires, or the child's lineage lands on the Null chain
      # writer and vanishes from the record -- silent record loss one level up,
      # per {Tools::Subagent}. The Null defaults live on the Seam and MATCH
      # Subagent's own, so omitting them is byte-identical to spawning the tool
      # directly; the loose pre-Seam keywords still work through `**spawn_over`,
      # and passing a seam AND its members raises. The tool guard is the one
      # member with no default, on the loose path as on the seam.
      def initialize(toolset:, slots:, seam: nil, max_depth: 1, **spawn_over)
        @seam = Tools::Subagent::Seam.resolve(seam, **spawn_over)
        @toolset = toolset
        @slots = slots
        @max_depth = max_depth
      end

      # `context_mode` names the prefix strategy directly (`:inherit` -> inherit
      # the parent conversation, `:fresh` -> a new root over the shared Store);
      # an unknown mode fails loudly through {Tool::SpawnPolicy::PrefixStrategy},
      # the same posture the catalog takes toward an unknown role.
      #
      # The model rides as a PER-CALL argument beside the role, not as a member
      # of the held seam: one instance answers a skill that declared a model, a
      # caller that picked one, and the run's own default, and only the seam is
      # the same for all three. A caller that names none passes nothing --
      # {Tools::Subagent::ModelChoice::Null} is the default, so no branch here
      # or below asks whether a model was chosen.
      def call(role_name, context_mode, prompt, model: Tools::Subagent::ModelChoice::Null)
        build_subagent(Role::Catalog.fetch(role_name), context_mode, model).run(prompt)
      end

      # This spawn, lending its children an environment the caller already
      # holds rather than leasing each a checkout of its own. Every other seam
      # member is unchanged, so they run behind the same guard and gate.
      #
      # @param worker_env [WorkerEnv] the held checkout's environment
      # @return [RoleSpawn]
      def within(worker_env)
        self.class.new(seam: @seam.with(isolation: lent(worker_env)), toolset: @toolset, slots: @slots,
                       max_depth: @max_depth)
      end

      # This spawn, its children built through the seam guard's never-parking
      # copy ({CLI::ToolGuard::NeverParking}): what an approval judge spawns
      # through, because it waits on the child with the judged call parked.
      #
      # @return [RoleSpawn]
      def never_parking
        self.class.new(seam: @seam.with(tool_middleware: @seam.tool_middleware.never_parking), toolset: @toolset,
                       slots: @slots, max_depth: @max_depth)
      end

      private

      # The caller's own lane travels with the lease it lends, so a lent
      # child's spawn says which issue it served rather than reading as the
      # run's own unnamed lane.
      def lent(worker_env)
        Isolation::Leases::InPlace.new(worker_env:, lane: @seam.isolation.lane)
      end

      # Everything the CALL decides: the role's policy, persona and child name,
      # plus the model this one child was bound to. The seam, union and ceiling
      # this instance already held.
      def build_subagent(role, context_mode, model)
        Tools::Subagent.new(
          seam: @seam, toolset: @toolset, policy: role.spawn_policy(prefix: context_mode),
          persona: Role::Persona.new(role:, slots: @slots), model:,
          max_depth: @max_depth, name: role.name.to_s
        )
      end
    end
  end
end
