# frozen_string_literal: true

require "yaml"

module Lain
  class Skill
    # The skill catalog: the shipped skills under `prompt/templates/skill/<name>/`
    # overlaid with a project's user skills under `.lain/skills/<name>/`, the user
    # version winning a name collision -- the same shipped-default-plus-`.lain`-
    # override convention {Prompt::Slots} reads for slots. Loaded once from disk
    # into a frozen, session-fixed instance (like Slots), rather than a mutable
    # registry; #fetch is loud on a miss, naming the known set.
    class Catalog
      class Unknown < Error; end

      # A skill.md whose front-matter cannot be read as intended: an opening
      # `---` fence that never closes (which would otherwise swallow the scaffold
      # into empty), front-matter that is not a YAML mapping, or malformed YAML.
      # Every one fails loudly AND named -- the same discipline as {Unknown} --
      # so a scaffold never vanishes in silence.
      class Malformed < Error; end

      # The shipped skills tree, a sibling of the prompt templates. Empty today
      # (just a `.keep`); skills land here as `<name>/skill.md` directories.
      SHIPPED_DIR = Paths::Shipped::SKILL_SHIPPED_DIR
      private_constant :SHIPPED_DIR

      # Every front-matter key `.build` reads. A key outside this set is
      # refused rather than ignored -- the same posture as `Config::Epics::KEYS`
      # -- so a typo (`slot:` for `slots:`) fails loudly instead of silently
      # leaving the skill un-slotted. `model:` is the key that makes the refusal
      # pay for itself twice over: a misspelled one would leave a skill running
      # on the run's model while its front-matter said otherwise, and nothing
      # downstream can tell an unnamed model from an unread one.
      KEYS = %w[description slots includes model].freeze

      class << self
        # Read the shipped skills, then overlay the project's user skills (a user
        # `<name>` REPLACES the shipped one of that name). The one disk read;
        # #fetch works from the returned frozen snapshot. `shipped_dir` is
        # injectable so a spec can load against a fixture tree without touching
        # the real shipped templates.
        def load(root: Dir.pwd, shipped_dir: SHIPPED_DIR)
          new(read_dir(shipped_dir).merge(read_dir(ProjectDir.new(root:).skills)))
        end

        private

        def read_dir(dir)
          Dir.glob(File.join(dir, "*", "skill.md")).each_with_object({}) do |path, skills|
            name = File.basename(File.dirname(path))
            skills[name.to_sym] = build(name, File.read(path))
          end
        end

        def build(name, source)
          meta, scaffold = split_front_matter(name, source)
          Skill.new(
            name:,
            description: meta.fetch("description", ""),
            scaffold:,
            slots: meta.fetch("slots", []),
            includes: meta.fetch("includes", []),
            model: model_name(name, meta)
          )
        end

        # `model:` is a NAME, so a sequence, a mapping or a number under that key
        # is refused rather than coerced. {Skill}'s own `to_s` would turn
        # `model: []` into the non-blank `"[]"` and send it to a provider as a
        # model id; KEYS argues a key nobody meant to write must not survive, and
        # a value nobody meant to write is the same argument one level down.
        #
        # A key written with nothing after it reads back as nil, which is a
        # declaration left blank rather than a wrong one, so it passes and lands
        # as the empty String every other unset member uses.
        def model_name(name, meta)
          model = meta["model"]
          unless model.nil? || model.is_a?(String)
            raise Malformed, "skill #{name.inspect} front-matter `model:` must be a model name, got " \
                             "#{model.class}"
          end

          model.to_s
        end

        # Front-matter is a leading `---`-fenced YAML block; everything after the
        # closing fence is the raw scaffold. No fence -> empty config, the whole
        # file is scaffold. The limit-3 split leaves any later `---` (a markdown
        # rule) inside the body untouched. An OPENING fence with no CLOSING fence
        # is a loud {Malformed}, never a silent scaffold-swallowed-whole -- the
        # split would otherwise yield two parts and drop the body to empty.
        def split_front_matter(name, source)
          return [{}, source] unless source.start_with?("---\n", "---\r\n")

          parts = source.split(/^---[ \t]*\r?\n/, 3)
          raise Malformed, "skill #{name.inspect} opens a `---` front-matter fence that never closes" \
            if parts.size < 3

          [parse_front_matter(name, parts[1]), parts[2].to_s]
        end

        # The fenced YAML as a mapping. Empty front-matter is an empty mapping; a
        # sequence or scalar is a loud {Malformed} (front-matter is keyed config,
        # not a list), and a YAML syntax error is wrapped named rather than
        # surfacing a bare Psych::SyntaxError -- every failure mode loud AND named.
        def parse_front_matter(name, front)
          meta = YAML.safe_load(front.to_s) || {}
          raise Malformed, "skill #{name.inspect} front-matter must be a mapping, got #{meta.class}" \
            unless meta.is_a?(Hash)

          unknown = meta.keys - KEYS
          unless unknown.empty?
            raise Malformed, "skill #{name.inspect} front-matter has unknown key(s) " \
                             "#{unknown.map(&:inspect).join(", ")}; known keys: #{KEYS.join(", ")}"
          end

          meta
        rescue Psych::SyntaxError => e
          raise Malformed, "skill #{name.inspect} has malformed YAML front-matter: #{e.message}"
        end
      end

      # Keyed by skill name (Symbol). Values are frozen {Skill}s, so a frozen
      # catalog over a frozen Hash is itself deeply immutable.
      def initialize(skills)
        @skills = skills.freeze
        freeze
      end

      # Loud and catalog-listing rather than nil: asking for a skill that does
      # not exist is a wiring error, and the message names the whole catalog.
      def fetch(name)
        @skills.fetch(name.to_sym) do
          raise Unknown, "unknown skill #{name.inspect}, expected one of #{names.inspect}"
        end
      end
      alias [] fetch

      # The catalog's skill names, in load order (shipped, then user additions).
      def names = @skills.keys

      def all = @skills.values
    end
  end
end
