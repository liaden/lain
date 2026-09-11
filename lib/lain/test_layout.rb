# frozen_string_literal: true

module Lain
  TestLayout = Data.define(:preset, :source_roots, :level_roots, :exempt)

  # Where a project keeps its tests: which directories hold source, which hold
  # each level's tests, and which test paths are exempt from the mirror.
  #
  #   [tests]
  #   preset = "rspec"
  #   source_roots = ["app"]
  #   level_roots = { unit = "spec/unit", seam = "spec/seam" }
  #   exempt = ["spec/*_discipline_spec.rb"]
  #
  # The mirror is relative to a source root, so `app/models/order.rb` mirrors
  # to `spec/unit/models/order_spec.rb`, never `spec/unit/app/models/...`.
  # A level's name doubles as the tag that marks it, which is how the guard
  # can tell a seam test that landed under the unit root.
  #
  # Exemption is only ever the project's own declaration. A preset exempts
  # nothing: support and fixture files are not test-named, so the guard never
  # holds them, and a test-named file among them is collected by the runner
  # like any other.
  #
  # Read by {Config.test_layout} rather than `Config.load`, because this table
  # restricts where a test may be written: a misspelt key silently leaving the
  # project unguarded is the worst outcome available, so it is refused.
  class TestLayout
    # A level root spelled this way keeps its tests inside the source file, as
    # Rust's `#[cfg(test)]` modules do, so there is no file to mirror.
    INLINE = "inline"

    PRESET = "preset"
    KEYS = [PRESET, "source_roots", "level_roots", "exempt"].freeze
    private_constant :PRESET, :KEYS

    # A test cannot be placed: no layout is in force, the level is not one the
    # layout declares or mirrors, or the source sits outside every source root.
    class Unplaceable < Error; end

    # Test files named `<stem><suffix><extension>`, as rspec's `_spec.rb`.
    Suffix = Data.define(:suffix, :extension) do
      def test?(basename) = basename.end_with?(ending) && basename.length > ending.length
      def test_name(source_basename) = "#{File.basename(source_basename, extension)}#{ending}"
      def source_name(test_basename) = "#{test_basename.delete_suffix(ending)}#{extension}"
      def ending = "#{suffix}#{extension}"
    end

    # Test files named `<prefix><stem><extension>`, as pytest's `test_*.py`.
    Prefix = Data.define(:prefix, :extension) do
      def test?(basename)
        basename.start_with?(prefix) && basename.end_with?(extension) &&
          basename.length > prefix.length + extension.length
      end

      def test_name(source_basename) = "#{prefix}#{source_basename}"
      def source_name(test_basename) = test_basename.delete_prefix(prefix)
    end

    # `mirrors` is false where a level's test files are not held to a source
    # file at all -- cargo's `tests/` is integration by definition. Only rspec
    # `describes` a constant the guard can check against the source.
    Preset = Data.define(:name, :test_file, :source_roots, :level_roots, :exempt, :mirrors, :describes) do
      def extension = test_file.extension
    end

    def self.levels_under(dir) = %w[unit seam integration].to_h { |level| [level, "#{dir}/#{level}"] }
    private_class_method :levels_under

    PRESETS = [
      Preset.new(name: "rspec", test_file: Suffix.new(suffix: "_spec", extension: ".rb"), source_roots: ["lib"],
                 level_roots: levels_under("spec"), exempt: [], mirrors: true, describes: true),
      Preset.new(name: "minitest", test_file: Suffix.new(suffix: "_test", extension: ".rb"), source_roots: ["lib"],
                 level_roots: levels_under("test"), exempt: [], mirrors: true, describes: false),
      Preset.new(name: "pytest", test_file: Prefix.new(prefix: "test_", extension: ".py"), source_roots: ["src"],
                 level_roots: levels_under("tests"), exempt: [], mirrors: true, describes: false),
      Preset.new(name: "cargo", test_file: Suffix.new(suffix: "", extension: ".rs"), source_roots: ["src"],
                 level_roots: { "unit" => INLINE, "integration" => "tests" }, exempt: [],
                 mirrors: false, describes: false)
    ].to_h { |preset| [preset.name, Ractor.make_shareable(preset)] }.freeze

    # A path the table names: relative, inside the project, and spelled one
    # way only, because a path is tested against it by prefix and `./app`
    # would silently miss everything under `app`. `-` is refused as a first
    # character because a level root reaches a test runner's command line,
    # where it would read as an option.
    module PathShape
      DOTS = %w[. ..].freeze

      module_function

      def canonical?(value)
        value.is_a?(String) && !value.empty? && !value.start_with?("/", "~", "-") &&
          value.split("/", -1).none? { |segment| segment.strip.empty? || DOTS.include?(segment) }
      end
    end

    # Two roots overlap when they are equal or one lies inside the other, so a
    # file under both would belong to each at once.
    module Overlap
      module_function

      def pair(paths) = paths.combination(2).find { |one, other| overlap?(one, other) }
      def overlap?(one, other) = one == other || one.start_with?("#{other}/") || other.start_with?("#{one}/")
    end

    # A refusal names the overlapping pair when that is what broke the rule,
    # since the shape alone would read as correct.
    module Clashing
      def describe(value)
        pair = clash(value)
        pair ? "#{self}; #{pair.join(" and ")} overlap" : to_s
      end
    end

    # Source roots may not overlap: a source under two of them would mirror to
    # two test paths, and the guard would pass one and refuse the other.
    Paths = Data.define(:minimum, :disjoint) do
      include Clashing

      def admits?(value) = shaped?(value) && !clash(value)

      def shaped?(value)
        value.is_a?(Array) && value.size >= minimum && value.all? { |path| PathShape.canonical?(path) }
      end

      def clash(value) = disjoint && shaped?(value) && Overlap.pair(value)

      def to_s = "a #{"non-empty " unless minimum.zero?}list of #{"distinct, non-nested " if disjoint}relative paths"
    end

    # Level roots may neither repeat nor nest: a file under two roots has two
    # levels, and no test path could satisfy both. `inline` is admitted only
    # for a preset whose levels do not mirror, since a mirrored test needs a
    # file of its own.
    Levels = Data.define(:inline) do
      include Clashing

      def admits?(value) = shaped?(value) && !clash(value)

      def shaped?(value) = value.is_a?(Hash) && !value.empty? && value.all? { |name, root| level?(name, root) }

      def level?(name, root)
        name.match?(/\A[a-z][a-z0-9_]*\z/) && (root == INLINE ? inline : PathShape.canonical?(root))
      end

      def clash(value) = shaped?(value) && Overlap.pair(value.values - [INLINE])

      def to_s
        "a table of lowercase level names to distinct, non-nested relative roots#{%( or "#{INLINE}") if inline}"
      end
    end

    OneOf = Data.define(:values) do
      def admits?(value) = values.include?(value)
      def describe(_value) = to_s
      def to_s = "one of #{values.join(", ")}"
    end

    private_constant :PathShape, :Overlap, :Clashing, :Paths, :Levels, :OneOf

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

    # @param table [Object] whatever `raw["tests"]` parsed to; nil when absent
    # @param path [String, nil] the config file, named by every refusal
    # @param framework [String, nil] the framework the caller detected, the
    #   fallback when there is no table; this class never detects one itself
    # @return [TestLayout] {None} when neither a table nor a known framework
    #   says what the layout is
    # @raise [Refusal] naming what is wrong with the table
    def self.from(table, path:, framework: nil)
      return detected(framework) if table.nil?

      shaped!(table, path:)
      defaults = preset(preset_named(table, path:))
      overrides = table.except(PRESET)
      admit!(overrides, defaults.preset, path:)
      new(**defaults.to_h, **overrides.transform_keys(&:to_sym))
    end

    # @param name [String] a key of {PRESETS}
    # @return [TestLayout] that preset's defaults
    def self.preset(name)
      preset = PRESETS.fetch(name)
      new(preset:, source_roots: preset.source_roots, level_roots: preset.level_roots, exempt: preset.exempt)
    end

    def self.detected(framework) = PRESETS.key?(framework) ? preset(framework) : None

    def self.shaped!(table, path:)
      raise NotATable.new(table, path:) unless table.is_a?(Hash)

      unknown = table.keys - KEYS
      raise UnknownKeys.new(unknown, path:) unless unknown.empty?
    end

    def self.preset_named(table, path:)
      name = table.fetch(PRESET) { raise MissingPreset.new(path:) }
      presets = OneOf.new(values: PRESETS.keys.sort.freeze)
      raise InvalidValue.new(PRESET, name, presets.describe(name), path:) unless presets.admits?(name)

      name
    end

    def self.admit!(overrides, preset, path:)
      rules = { "source_roots" => Paths.new(minimum: 1, disjoint: true),
                "level_roots" => Levels.new(inline: !preset.mirrors),
                "exempt" => Paths.new(minimum: 0, disjoint: false) }
      overrides.each do |key, value|
        rule = rules.fetch(key)
        raise InvalidValue.new(key, value, rule.describe(value), path:) unless rule.admits?(value)
      end
    end

    private_class_method :detected, :shaped!, :preset_named, :admit!

    # Copies, not the caller's strings: the table arrives from a TOML parse the
    # caller still holds, and this value has to stay `Ractor.shareable?`.
    def initialize(preset:, source_roots:, level_roots:, exempt:)
      super(preset:, source_roots: source_roots.map { |root| root.dup.freeze }.freeze,
            level_roots: level_roots.to_h { |name, root| [name.dup.freeze, root.dup.freeze] }.freeze,
            exempt: exempt.map { |glob| glob.dup.freeze }.freeze)
    end

    # @return [Boolean] false only for {None}, which guards nothing
    def in_force? = !level_roots.empty?

    # @return [Mapping] the path arithmetic this layout implies
    def mapping = Mapping.new(self)

    # The layout of a project that declared none and whose framework nothing
    # detected: no level roots, so no path is ever under one and nothing is
    # guarded, while a placement is refused loudly rather than guessed.
    None = new(preset: Ractor.make_shareable(Preset.new(name: "none", test_file: Suffix.new(suffix: "", extension: ""),
                                                        source_roots: [], level_roots: {}, exempt: [],
                                                        mirrors: false, describes: false)),
               source_roots: [], level_roots: {}, exempt: [])
  end
end

# The parts reopen the class, so they load once `Data.define` has made it.
require_relative "test_layout/mapping"
require_relative "test_layout/constant_index"
require_relative "test_layout/guard"
