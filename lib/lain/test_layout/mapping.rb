# frozen_string_literal: true

module Lain
  class TestLayout
    # The path arithmetic a layout implies, between a source file and the test
    # file that holds its tests at a level. Pure: it never asks the filesystem
    # whether either file exists, which is the guard's question.
    #
    # Every path in and out is relative to the project root.
    class Mapping
      # `:mirrored` holds one test file per source file, `:inline` keeps the
      # tests inside the source, and `:flat` holds test files no source is
      # answerable for.
      Level = Data.define(:name, :root, :shape) do
        def holds?(path) = shape != :inline && (path == root || path.start_with?("#{root}/"))
        def mirrored? = shape == :mirrored
        def flat? = shape == :flat
      end

      attr_reader :levels

      # @param layout [TestLayout]
      def initialize(layout)
        @layout = layout
        @test_file = layout.preset.test_file
        @levels = layout.level_roots.map { |name, root| Level.new(name:, root:, shape: shape_of(root)) }.freeze
        @package_roots = package_roots_by_level
        @trees = @levels.select(&:mirrored?).map { |level| level.root.split("/").first }.uniq.freeze
        freeze
      end

      # @param name [String]
      # @return [Level]
      # @raise [Unplaceable] naming the levels the layout does declare
      def level(name)
        @levels.find { |level| level.name == name } or
          raise Unplaceable, "no #{name.inspect} level in this test layout; " \
                             "its levels are #{@levels.map(&:name).join(", ")}"
      end

      # Level roots never nest (the `tests` reader refuses it), so at most
      # one holds a path. A flat level holds the root of every package, the
      # same ones {#test_path} places into.
      # @return [Level, nil] nil for a path under no level root
      def level_of(path)
        @levels.find do |level|
          level.holds?(path) || @package_roots.fetch(level.name, []).any? { |root| path.start_with?("#{root}/") }
        end
      end

      # The level a test that names none belongs to, in the order the answer is
      # settled: what the table DECLARES; else the only level that mirrors, if
      # there is only one; else {TestLayout::DEFAULT_LEVEL} wherever the table
      # declares it.
      #
      # What it deliberately no longer does is fall back to "the first mirrored
      # level". `level_roots` is a TOML table, so its Ruby order is the order
      # the author typed the keys -- and two things act on this answer without
      # ever naming it: the guard judges every untagged test against it, and
      # the epic driver WRITES an issue's failing tests there. So re-ordering
      # two lines of TOML silently moved both. A table that leaves the choice
      # open is refused at load instead ({TestLayout.settled!}),
      # which is why callers reached from a loaded table never see the nil.
      # With no mirrored level (cargo), the answer comes from the inline levels,
      # since the tests live beside the source.
      # @return [Level, nil] nil when the layout settles on no level
      def default_level
        candidates = placing_levels
        return candidates.find { |level| level.name == @layout.default_level } if @layout.default_level
        return candidates.first if candidates.one?

        candidates.find { |level| level.name == TestLayout::DEFAULT_LEVEL }
      end

      # A test file inside the test tree -- the top directory of a mirrored
      # level root -- but under no level root. The runner collects it all the
      # same, since rspec globs `spec/**/*_spec.rb`, so it must not be a way
      # around the guard.
      def stray?(path)
        test_file?(path) && level_of(path).nil? && @trees.any? { |tree| path.start_with?("#{tree}/") }
      end

      # Exemptions are path globs, never file contents. `*` crosses directory
      # separators here, so `spec/support/**` exempts the whole subtree.
      def exempt?(path) = @layout.exempt.any? { |glob| File.fnmatch?(glob, path, File::FNM_DOTMATCH) }

      def test_file?(path) = @test_file.test?(File.basename(path))

      # @param path [String] a test file
      # @return [Array<String>] the source it mirrors, one candidate per source
      #   root; empty unless it is a test file under a mirrored level root
      def sources_for(path)
        level = level_of(path)
        return [] unless level&.mirrored? && test_file?(path)

        relative = path.delete_prefix("#{level.root}/")
        name = @test_file.source_name(File.basename(relative))
        @layout.source_roots.map { |root| joined(root, File.dirname(relative), name) }
      end

      # A flat level's root is resolved against the source's package, the
      # directory its source root sits in, so each member of a workspace keeps
      # its own `tests/`, as cargo runs them.
      #
      # @param source [String] a source file under one of the source roots
      # @param level [String] a level the layout declares
      # @param name [String, nil] what a flat level's test file is named for;
      #   a mirrored or inline level takes its name from the source
      # @return [String] where that source's tests at that level belong
      # @raise [Unplaceable] when no layout is in force, a flat level is given
      #   no name, or the source is outside every source root
      def test_path(source, level:, name: nil)
        unless @layout.in_force?
          raise Unplaceable, "no test layout is in force, so a test for #{source} has nowhere to go"
        end

        target = self.level(level)
        root = source_root_of(source)
        return source if target.shape == :inline
        return flat_path(target, root, name) if target.flat?

        relative = source.delete_prefix("#{root}/")
        joined(target.root, File.dirname(relative), @test_file.test_name(File.basename(relative)))
      end

      # Where a red step may leave helpers beside its tests: the top of each
      # mirrored root, and each package's own flat root.
      # @return [Array<String>]
      def test_trees
        (@trees + @package_roots.values.flatten).uniq
      end

      private

      def package_roots_by_level
        @levels.select(&:flat?).to_h do |level|
          [level.name, @layout.source_roots.map { |root| joined(File.dirname(root), level.root) }.uniq]
        end
      end

      def placing_levels
        mirrored = @levels.select(&:mirrored?)
        mirrored.empty? ? @levels.select { |level| level.shape == :inline } : mirrored
      end

      def shape_of(root)
        return :inline if root == INLINE

        @layout.preset.mirrors ? :mirrored : :flat
      end

      def source_root_of(source)
        root = @layout.source_roots.select { |candidate| source.start_with?("#{candidate}/") }.max_by(&:length)
        return root if root && source.end_with?(@test_file.extension)

        raise Unplaceable, "#{source} is not a #{@test_file.extension} file under a source root " \
                           "(#{@layout.source_roots.join(", ")})"
      end

      def flat_path(level, source_root, name)
        if name.nil?
          raise Unplaceable, "the #{level.name} level's tests under #{level.root} mirror no source file, " \
                             "so its test file needs a name and none was given"
        end

        joined(File.dirname(source_root), level.root, @test_file.test_name("#{name}#{@test_file.extension}"))
      end

      # `File.dirname` answers "." for a file at a root's top, which must not
      # become a path segment.
      def joined(*parts) = File.join(*parts.reject { |part| part == "." })
    end
  end
end
