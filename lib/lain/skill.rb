# frozen_string_literal: true

module Lain
  # A named, reusable prompt scaffold plus the config saying how it slots into a
  # spawn. CONFIG ONLY -- a Skill renders nothing, spawns nothing, calls no
  # agent, and there is deliberately no +Skill#call+: the config-vs-behavior
  # boundary is the whole point of the value, exactly as for a {Role}.
  #
  # A skill ships as `<name>/skill.md`, a YAML front-matter block above a
  # markdown scaffold. {Skill::Catalog} owns loading and the
  # shipped-default-plus-`.lain`-override convention.
  #
  # Deeply frozen so `Ractor.shareable?(skill)` holds.
  Skill = Data.define(:name, :description, :scaffold, :slots, :includes) do
    # Every String field is frozen EXPLICITLY rather than assumed frozen:
    # interpolation and Symbol#to_s both hand back mutable Strings, and the
    # value's shareability depends on neither slipping through.
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
# the value above.
# Library pairs the Catalog above with Prompt::Slots and composes the Renderer,
# so it loads last.
