# frozen_string_literal: true

module Lain
  TestLayout = Data.define(:preset, :source_roots, :level_roots, :exempt, :default_level)

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

    # The level name every preset ships, and the one an untagged test belongs
    # to wherever a table declares it: an untagged test claims nothing about
    # being slow, so the fastest level is where it is held to.
    DEFAULT_LEVEL = "unit"

    PRESET = "preset"
    KEYS = [PRESET, "source_roots", "level_roots", "exempt", "default_level"].freeze
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
      settled!(new(**defaults.to_h, **overrides.transform_keys(&:to_sym)), path:)
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
      presets = Shapes::OneOf.new(values: PRESETS.keys.sort.freeze)
      raise InvalidValue.new(PRESET, name, presets.describe(name), path:) unless presets.admits?(name)

      name
    end

    def self.admit!(overrides, preset, path:)
      rules = { "source_roots" => Shapes::Paths.new(minimum: 1, disjoint: true),
                "level_roots" => Shapes::Levels.new(inline: !preset.mirrors),
                "exempt" => Shapes::Paths.new(minimum: 0, disjoint: false) }
      overrides.except("default_level").each do |key, value|
        rule = rules.fetch(key)
        raise InvalidValue.new(key, value, rule.describe(value), path:) unless rule.admits?(value)
      end
      declared!(overrides, preset, path:)
    end

    # `default_level` is the one CROSS-FIELD rule -- it has to name a level the
    # table declares -- so it is judged only once `level_roots` has been
    # admitted. Reading an unadmitted `level_roots` here meant a malformed one
    # crashed this rule instead of being refused as itself.
    def self.declared!(overrides, preset, path:)
      return unless overrides.key?("default_level")

      value = overrides.fetch("default_level")
      rule = Shapes::OneOf.new(values: (overrides["level_roots"] || preset.level_roots).keys)
      raise InvalidValue.new("default_level", value, rule.describe(value), path:) unless rule.admits?(value)
    end

    # The table is read eagerly so it can be REFUSED; an undeterminable
    # default level belongs in that refusal rather than at the first untagged
    # test. See {AmbiguousDefaultLevel}.
    def self.settled!(layout, path:)
      return layout if layout.default_level || layout.mapping.default_level

      mirrored = layout.mapping.levels.select(&:mirrored?).map(&:name)
      return layout if mirrored.size < 2

      raise AmbiguousDefaultLevel.new(mirrored, path:)
    end

    private_class_method :detected, :shaped!, :preset_named, :admit!, :declared!, :settled!

    # Never the caller's own strings: the table arrives from a TOML parse the
    # caller still holds, and this value has to stay `Ractor.shareable?`.
    # {Freezable::Fields} is the one owner of that normalization -- interned,
    # with nil kept as the absence it signals, which is exactly what an
    # undeclared `default_level` is.
    def initialize(preset:, source_roots:, level_roots:, exempt:, default_level: nil)
      pin = Freezable::Fields
      super(preset:, source_roots: pin.pinned_each(source_roots), exempt: pin.pinned_each(exempt),
            level_roots: level_roots.to_h { |name, root| [pin.pinned(name), pin.pinned(root)] }.freeze,
            default_level: pin.pinned(default_level))
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
require_relative "test_layout/shapes"
require_relative "test_layout/refusals"
require_relative "test_layout/mapping"
require_relative "test_layout/constant_index"
require_relative "test_layout/guard"
