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
      end

      attr_reader :levels

      # @param layout [TestLayout]
      def initialize(layout)
        @layout = layout
        @test_file = layout.preset.test_file
        @levels = layout.level_roots.map { |name, root| Level.new(name:, root:, shape: shape_of(root)) }.freeze
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

      # Level roots never nest (the `[tests]` reader refuses it), so at most
      # one holds a path.
      # @return [Level, nil] nil for a path under no level root
      def level_of(path) = @levels.find { |level| level.holds?(path) }

      # The level a test that names none belongs to: `unit` wherever the table
      # declares it, since an untagged test claims nothing about being slow,
      # and otherwise the first level that mirrors.
      # @return [Level, nil] nil when no level mirrors
      def default_level
        mirrored = @levels.select(&:mirrored?)
        mirrored.find { |level| level.name == "unit" } || mirrored.first
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

      # @param source [String] a source file under one of the source roots
      # @param level [String] a level the layout declares
      # @return [String] where that source's tests at that level belong
      # @raise [Unplaceable] when no layout is in force, the level mirrors no
      #   source, or the source is outside every source root
      def test_path(source, level:)
        unless @layout.in_force?
          raise Unplaceable, "no test layout is in force, so a test for #{source} has nowhere to go"
        end

        target = self.level(level)
        relative = relative_to_source_root(source)
        return source if target.shape == :inline

        unless target.mirrored?
          raise Unplaceable, "the #{target.name} level's tests under #{target.root} do not mirror a source file"
        end

        joined(target.root, File.dirname(relative), @test_file.test_name(File.basename(relative)))
      end

      private

      def shape_of(root)
        return :inline if root == INLINE

        @layout.preset.mirrors ? :mirrored : :flat
      end

      def relative_to_source_root(source)
        root = @layout.source_roots.select { |candidate| source.start_with?("#{candidate}/") }.max_by(&:length)
        unless root && source.end_with?(@test_file.extension)
          raise Unplaceable, "#{source} is not a #{@test_file.extension} file under a source root " \
                             "(#{@layout.source_roots.join(", ")})"
        end

        source.delete_prefix("#{root}/")
      end

      # `File.dirname` answers "." for a file at a root's top, which must not
      # become a path segment.
      def joined(*parts) = File.join(*parts.reject { |part| part == "." })
    end
  end
end
