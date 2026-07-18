# frozen_string_literal: true

module Lain
  module Prompt
    # The two-level skill-slot region: a hole's project override at
    # `.lain/slots/skill/<skill>/<hole>.md` layered over a shipped default at
    # `templates/skill/<skill>/<hole>.md`. Unlike the FLAT one-per-role region
    # {Slots} reads with a single glob, a skill has MANY holes, so both trees are
    # `<skill>/<hole>` deep -- a distinct enough shape to be its own object.
    #
    # It owns the disk read and the override-then-default lookup with its loud
    # miss; the pure ERB render of the resolved source stays in
    # {Slots#render_skill}, which owns the locked binding. Read once from disk,
    # deeply frozen -- session-fixed, exactly like the rest of {Slots}.
    class SkillSlots
      class << self
        # Two-level read: `<dir>/<skill>/<hole>.md` -> `{ skill => { hole =>
        # body } }`. `skill.md` is the SCAFFOLD ({Skill::Catalog} reads it),
        # never a hole, so it is excluded. Inner hashes freeze so the whole
        # two-level structure is deeply immutable.
        def read(dir)
          Dir.glob(File.join(dir, "*", "*.md"))
             .reject { |path| File.basename(path, ".md") == "skill" }
             .group_by { |path| File.basename(File.dirname(path)) }
             .transform_values { |paths| read_holes(paths).freeze }
             .freeze
        end

        private

        def read_holes(paths)
          paths.to_h { |path| [File.basename(path, ".md"), File.read(path)] }
        end
      end

      def initialize(fills:, templates:)
        @fills = fills
        @templates = templates
        freeze
      end

      # A hole's active partial SOURCE: the project override, else the shipped
      # default. An empty override (a deliberately blanked hole) is a String and
      # therefore wins; only a hole present in NEITHER tree is the nil that fails
      # loudly, naming the skill and the holes it does know.
      def source(skill, hole)
        name = skill.to_s
        slot = hole.to_s
        source = @fills.dig(name, slot) || @templates.dig(name, slot)
        return source unless source.nil?

        raise UnknownSlot, "unknown skill slot #{slot.inspect} for skill #{name.inspect}; " \
                           "known holes: #{known(name).inspect}"
      end

      private

      def known(name) = (@templates[name] || {}).keys | (@fills[name] || {}).keys
    end
  end
end
