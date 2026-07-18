# frozen_string_literal: true

module Lain
  # A skill: a named, reusable prompt scaffold plus the config saying how it slots
  # into a spawn. CONFIG ONLY -- a Skill renders nothing, spawns nothing, calls no
  # agent. It is the recipe a later seam reads (A2 renders the scaffold, B2
  # dispatches it); holding one grants no behavior, exactly as holding a {Role}
  # value is a recipe and not a running child. There is deliberately no
  # +Skill#call+: the config-vs-behavior boundary is the whole point of the value.
  #
  # A skill ships as a directory `<name>/skill.md` -- a YAML front-matter block
  # (description, declared slots, declared includes) above a markdown scaffold.
  # {Skill::Catalog} owns loading and the shipped-default-plus-`.lain`-override
  # convention, the same shape {Prompt::Slots} reads for slots.
  #
  # Deeply frozen so `Ractor.shareable?(skill)` holds -- the mechanical statement
  # that the value carries no reachable mutable state.
  Skill = Data.define(:name, :description, :scaffold, :slots, :includes) do
    # `name` is the catalog key (the skill dir's basename). The String fields are
    # frozen and the list fields normalize to frozen Symbol arrays, so the whole
    # value is shareable -- interpolation and Symbol#to_s both hand back MUTABLE
    # Strings, which is why each is frozen explicitly rather than assumed frozen.
    def initialize(name:, description:, scaffold:, slots: [], includes: [])
      super(
        name: name.to_sym,
        description: description.to_s.freeze,
        scaffold: scaffold.to_s.freeze,
        slots: Array(slots).map(&:to_sym).freeze,
        includes: Array(includes).map(&:to_sym).freeze
      )
    end
  end
end

# The catalog and the invocation parser both reopen Skill, so they load after
# the value above -- skill.rb is this subtree's index, the same ordering role.rb
# uses for role/catalog.
require_relative "skill/catalog"
require_relative "skill/invocation"
require_relative "skill/role_spawn"
require_relative "skill/renderer"
