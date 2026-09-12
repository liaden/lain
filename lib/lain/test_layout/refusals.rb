# frozen_string_literal: true

module Lain
  class TestLayout
    # Every refusal of a `[tests]` table, so a caller that degrades a bad
    # table to a notice can rescue them all at once. The path is absent for a
    # table built by hand rather than read from a file.
    class Refusal < Error
      attr_reader :path

      def initialize(detail, path:)
        @path = path
        super("#{"#{path}: " if path}[tests] #{detail}")
      end
    end

    # `[tests]` present but not a table.
    class NotATable < Refusal
      attr_reader :value

      def initialize(value, path:)
        @value = value
        super("must be a table, got #{value.class}: #{value.inspect}", path:)
      end
    end

    # A typo inside the table: refused, because a misspelt `source_roots`
    # would otherwise guard the preset's roots while the author believes their
    # own are in force.
    class UnknownKeys < Refusal
      attr_reader :keys

      def initialize(keys, path:)
        @keys = keys
        super("has no keys #{keys.map(&:inspect).join(", ")}; known keys: #{KEYS.join(", ")}", path:)
      end
    end

    # Every other key defaults from the preset, so without one the table
    # cannot say what it overrides.
    class MissingPreset < Refusal
      def initialize(path:) = super("names no preset; set preset to one of #{PRESETS.keys.sort.join(", ")}", path:)
    end

    # A key's value outside its rule, named with the rule it broke.
    class InvalidValue < Refusal
      attr_reader :key, :value

      def initialize(key, value, rule, path:)
        @key = key
        @value = value
        super("#{key} = #{value.inspect} is not #{rule}", path:)
      end
    end

    # Mirrored levels the table leaves a choice between, with nothing naming
    # which one an untagged test belongs to. Refused at LOAD, because the two
    # things that ride the answer both act on it silently: the guard judges
    # every untagged test against that level, and the epic driver WRITES an
    # issue's failing tests there. The previous answer was "whichever mirrored
    # level the author happened to type first", so re-ordering two lines of
    # TOML moved both -- which is precisely the kind of quiet wrong answer this
    # table is read eagerly in order to refuse.
    class AmbiguousDefaultLevel < Refusal
      attr_reader :candidates

      def initialize(candidates, path:)
        @candidates = candidates
        super("declares no #{DEFAULT_LEVEL.inspect} level and mirrors more than one " \
              "(#{candidates.join(", ")}), so nothing says where a test that names no level belongs; " \
              "add default_level = \"<one of them>\"", path:)
      end
    end
  end
end
