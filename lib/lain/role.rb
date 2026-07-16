# frozen_string_literal: true

module Lain
  # A subagent role: a named capability attenuation plus a role-specific prompt
  # slot. A role is the three-way join OM-5 describes -- {Toolset#only}
  # attenuation, a role slot (`.lain/slots/role/<name>.md`, PS-3), and a spawn
  # {Tool::SpawnPolicy::AttenuationPosture} -- packaged as a value a spawn seam
  # reads. Possessing a Role is a recipe, not a running child: it yields the
  # policy the {Tools::Subagent} tool takes and the system prelude the child
  # renders, and nothing about the Subagent surface changes to consume them.
  #
  # == The prelude ordering (pinned)
  #
  # A role's rendered prelude is the role-invariant preamble FIRST -- the base
  # system prompt every sibling role shares -- then the role-specific slot. The
  # order is load-bearing money, not taste: the shared bulk sits above the cache
  # line so heterogeneous sibling spawns share one warm prefix (CE-4), and only
  # the short role tail differs. Two spawns of one role in a session render
  # byte-identical (slots are session-fixed); two different roles share every
  # byte up to their role slot.
  Role = Data.define(:name, :only) do
    # `name` is the catalog key (`:test_engineer`); `only` normalizes to frozen
    # Symbols -- the tool names this role attenuates the spawn's union down to.
    def initialize(name:, only:)
      super(name: name.to_sym, only: Array(only).map(&:to_sym).freeze)
    end

    # The on-disk basename of this role's slot: the pinned underscores-to-hyphens
    # mapping, owned by {Prompt::Slots}. `:test_engineer` -> `"test-engineer"`.
    def slot_name = Prompt::Slots.role_slot_name(name)

    # The child's capability set: the spawn's union attenuated DOWN to `only`.
    # Requesting a tool the union does not hold raises through {Toolset#only},
    # so a role that names a phantom tool fails loudly at spawn rather than
    # silently granting less than it claims.
    def attenuate(union) = union.only(*only)

    # The spawn policy the {Tools::Subagent} tool reads: this role's `only`-set
    # under the caller's chosen prefix/posture arms. `only` is the role's; the
    # two axes are the spawner's to pick (a role is capability-shaped, not
    # cache-strategy-shaped), so they default to the conservative arms.
    def spawn_policy(prefix: :fresh, posture: :schema)
      Tool::SpawnPolicy.new(prefix:, posture:, only:)
    end

    # The child's system prelude as SEGMENTS, in the pinned order: the
    # role-invariant bulk first, then this role's tail. Frozen, two elements.
    # This -- not the joined String below -- is the cache-bearing surface: the
    # spawn seam renders each segment as its own system block and marks the
    # BULK, so the breakpoint sits between them and heterogeneous siblings
    # share the cached tools-plus-bulk prefix (CE-4). A fused String cannot
    # deliver that: one block gets one mark, after the role tail. Pure over
    # the session-fixed `slots`, so repeated spawns render byte-identically.
    def prelude_segments(slots:)
      [slots.render("system").freeze, slots.render_role(name).freeze].freeze
    end

    # The segments joined, for display and byte-level comparison only -- as a
    # single String it earns no sibling cache sharing (see {#prelude_segments}
    # for why, and for the surface a spawn seam should consume instead).
    def prelude(slots:)
      prelude_segments(slots:).join("\n\n")
    end
  end
end

# The built-in catalog reopens nothing but references Role.new, so it loads after
# the value above -- role.rb is this subtree's index (the effect/handler pattern).
require_relative "role/catalog"
