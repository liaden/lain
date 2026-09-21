# frozen_string_literal: true

module Lain
  Role = Data.define(:name, :only, :unattended) do
    # `name` is the catalog key (`:test_engineer`); `only` normalizes to frozen
    # Symbols -- the tool names this role attenuates the spawn's union down to.
    # `unattended` is the guarantee described on the reopened class below. It
    # normalizes to a REAL boolean like every member beside it, and defaults to
    # false: a role CLAIMS the guarantee, it never inherits one.
    def initialize(name:, only:, unattended: false)
      super(name: name.to_sym, only: Array(only).map(&:to_sym).freeze,
            unattended: unattended ? true : false)
    end

    # The child's capability set: the spawn's union attenuated DOWN to `only`.
    # Requesting a tool the union does not hold raises through {Toolset#only},
    # so a role that names a phantom tool fails loudly at spawn rather than
    # silently granting less than it claims.
    def attenuate(union) = union.only(*only)

    # The spawn policy the {Tools::Subagent} tool reads: this role's `only`-set
    # and its unattended declaration, under the caller's chosen prefix/posture
    # arms. Both role-derived members are the role's; the two axes are the
    # spawner's to pick (a role is capability-shaped, not cache-strategy-shaped),
    # so they default to the conservative arms. This is the ONLY channel the
    # declaration has -- a {Tools::Subagent::ChildBuilder} holds a policy and
    # never the Role it was built from.
    def spawn_policy(prefix: :fresh, posture: :schema)
      Tool::SpawnPolicy.new(prefix:, posture:, only:, unattended:)
    end

    # The child's system prelude as SEGMENTS: the role-invariant bulk first,
    # then this role's tail. This -- not the joined String below -- is the
    # cache-bearing surface. The spawn seam renders each segment as its own
    # system block and marks the BULK, so the breakpoint sits between them and
    # heterogeneous siblings share the cached tools-plus-bulk prefix; a fused
    # String cannot, because one block gets one mark, after the role tail. Pure
    # over the session-fixed `slots`, so repeated spawns render byte-identically.
    def prelude_segments(slots:)
      [slots.render("system").freeze, slots.render_role(name).freeze].freeze
    end

    # The segments joined, for display and byte-level comparison only -- as a
    # single String it earns no sibling cache sharing (see {#prelude_segments}
    # for why, and for the surface a spawn seam should consume instead).
    def prelude(slots:)
      prelude_segments(slots:).join("\n\n")
    end

    # The factory Context reshaped into this role's persona. Its system BECOMES
    # the prelude segments as two blocks -- the shared bulk cache-marked, the
    # role tail unmarked after the breakpoint -- REPLACING the factory's own
    # system, never appending: the bulk already IS `slots.render("system")`, so
    # appending to a factory whose system is that same render would emit the
    # bulk twice. Everything else -- the render pipeline included -- rides
    # through unchanged.
    def child_context(context, slots:)
      bulk, tail = prelude_segments(slots:)
      context.with_system([{ "type" => "text", "text" => bulk, "cache" => true }, { "type" => "text", "text" => tail }])
    end
  end

  # A subagent role: a three-way join of {Toolset#only} attenuation, a role slot
  # (`.lain/slots/role/<name>.md`) and a spawn
  # {Tool::SpawnPolicy::AttenuationPosture}, packaged as a value a spawn seam
  # reads. Possessing a Role is a recipe, not a running child.
  #
  # **The prelude ordering is pinned**: role-invariant preamble FIRST, then the
  # role-specific slot. That order is load-bearing money, not taste -- the
  # shared bulk sits above the cache line, so heterogeneous sibling spawns share
  # one warm prefix and only the short role tail differs.
  #
  # **An unattended role declares something `only` cannot express**: that it
  # never asks a human, because it answers with nobody minding it. Naming the
  # guarantee rather than the tool is the point -- `ask_human` is the only tool
  # that asks today, and a second one must not quietly reach such a role later.
  # `only` cannot say it because the asker is granted OUTSIDE the attenuation, at
  # the spawn ({Tools::Subagent::ChildBuilder}). Whether a child's gated call
  # may park on the approval gate is not the role's to say: the spawn site
  # decides that ({Skill::RoleSpawn#never_parking}).
  class Role
    # Reopened rather than defined in the `Data.define ... do` block above: a
    # constant declared inside that block scopes to the enclosing module, not the
    # Data class (the trap {Request::SYSTEM_PREFIX} documents), so `Persona` would
    # land as `Lain::Persona`, not `Role::Persona`.

    # A {Role} paired with the session {Prompt::Slots}, so a spawn seam can
    # reshape a child's factory Context into the role persona
    # ({Role#child_context}) without itself carrying either dependency. The seam
    # holds ONE injected collaborator and asks it `child_context`, never
    # branching on whether a role is present -- {Persona::Null} answers the same
    # message with the factory context untouched.
    Persona = Data.define(:role, :slots) do
      def child_context(context) = role.child_context(context, slots:)
    end

    class Persona
      # Reopened (the effect/handler idiom) to hold the Null identity beside the
      # value: no role wired means the child keeps the factory Context
      # byte-for-byte, so a roleless spawn renders exactly as it did before
      # roles existed. Frozen -- deep immutability is the shareable discipline.
      Null = Class.new do
        def child_context(context) = context
      end.new.freeze
    end
  end
end
