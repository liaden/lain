# frozen_string_literal: true

require "prism"

module Lain
  class TestLayout
    # Where a Ruby constant is defined, read with Prism. The direction is
    # constant to file, never file to constant, so `CLI::Backend` is found in
    # `cli/backend.rb` without an inflection table that knows `CLI` is an
    # acronym.
    #
    # Built once per session and asked lazily: a passing check parses only the
    # file its test mirrors, and a file is parsed again only once its stat
    # changes, because the agent this guards is editing those files.
    class ConstantIndex
      # What one source file defines. `status` is `:absent`, `:parsed` or
      # `:unparseable`; `error` is the parser's reason for the last.
      FileConstants = Data.define(:path, :status, :names, :error) do
        def self.absent(path) = new(path:, status: :absent, names: [], error: nil)

        def initialize(path:, status:, names:, error:)
          super(path: path.dup.freeze, status:, names: names.map { |name| name.dup.freeze }.uniq.freeze,
                error: error&.dup&.freeze)
        end

        def exists? = status != :absent
        def parsed? = status == :parsed
        def unparseable? = status == :unparseable
        def defines?(name) = names.include?(name)
      end

      Entry = Data.define(:stamp, :constants)
      UNREAD = Entry.new(stamp: nil, constants: nil)

      # A byte that may continue a constant's name: ASCII word characters, and
      # any byte of a multi-byte UTF-8 character, which Ruby also admits.
      WORD = "[A-Za-z0-9_\\x80-\\xff]"
      private_constant :Entry, :UNREAD, :WORD

      # Every constant a file opens or assigns, qualified by its lexical
      # nesting. A constant assigned inside a block belongs to the enclosing
      # namespace, as Ruby scopes it.
      class Collector < Prism::Visitor
        attr_reader :names

        def initialize
          super
          @nesting = []
          @names = []
        end

        def visit_class_node(node) = opening(node.constant_path) { super }
        def visit_module_node(node) = opening(node.constant_path) { super }

        def visit_constant_write_node(node)
          @names << qualified(node.name.to_s)
          super
        end

        def visit_constant_or_write_node(node)
          @names << qualified(node.name.to_s)
          super
        end

        # Each constant a multiple assignment (`Low, High = 1, 9`) targets.
        def visit_constant_target_node(node)
          @names << qualified(node.name.to_s)
          super
        end

        def visit_constant_path_write_node(node)
          @names.concat(readings(node.target))
          super
        end

        def visit_constant_path_or_write_node(node)
          @names.concat(readings(node.target))
          super
        end

        def visit_constant_path_target_node(node)
          @names.concat(readings(node))
          super
        end

        # Ruby refuses a constant defined in a method body, so nothing there
        # can be found and the walk is spared it.
        def visit_def_node(_node) = nil

        private

        def opening(path)
          names = readings(path)
          @names.concat(names)
          @nesting.push(names.first || @nesting.last)
          yield
        ensure
          @nesting.pop
        end

        # Empty for a path with a dynamic part (`klass::Inner`), which names
        # no constant this index could look up.
        def readings(path)
          return [qualified(path.name.to_s)] unless compact?(path)

          name = path.full_name
          name.start_with?("::") ? [name.delete_prefix("::")] : anchored(name)
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          []
        end

        def compact?(path) = path.is_a?(Prism::ConstantPathNode) || path.is_a?(Prism::ConstantPathTargetNode)

        # A compact path's head is looked up lexically, innermost namespace
        # outward, so `Shop::Limit = 3` inside `module Shop` is `Shop::Limit`.
        # A head no enclosing namespace is named for resolves to whichever
        # constant exists when the line runs, which a static read cannot know,
        # so both readings are kept: nested first, then top-level.
        def anchored(name)
          head, rest = name.split("::", 2)
          outer = @nesting.compact.reverse.find { |namespace| namespace.split("::").last == head }
          outer ? ["#{outer}::#{rest}"] : [qualified(name), name].uniq
        end

        def qualified(name) = [@nesting.last, name].compact.join("::")
      end

      # @param root [String] the project root every path is relative to
      # @param source_roots [Array<String>] where {#definitions_of} looks
      # @param extension [String] the source files' extension
      # @param parse [#call] parses the file at an absolute path; injected so
      #   the cost of a search, which is the files it parses, can be counted
      def initialize(root:, source_roots:, extension:, parse: Prism.method(:parse_file))
        @root = root
        @source_roots = source_roots
        @extension = extension
        @parse = parse
        @read = {}
      end

      # @param path [String] relative to the root
      # @return [FileConstants]
      def constants_in(path)
        stamp = stamp_of(path)
        return FileConstants.absent(path) if stamp.nil?

        entry = @read.fetch(path, UNREAD)
        return entry.constants if entry.stamp == stamp

        constants = parse(path)
        @read[path] = Entry.new(stamp:, constants:)
        constants
      end

      # The file named for the constant is offered first, since a constant
      # reopened across files is most at home there.
      #
      # A file is parsed only if its bytes spell every segment of the name and
      # something shaped like a definition of the last one. Defining
      # `Lain::Ghost::Error` statically means writing each of those words, while
      # a common last segment like `Error` alone appears in most of a tree --
      # filtering on it alone once parsed 425 files to answer a miss.
      #
      # @param name [String] a fully-qualified constant name, without a leading `::`
      # @return [Enumerator::Lazy<String>] the files under the source roots that define it
      def definitions_of(name)
        segments = name.split("::").map(&:b)
        shape = definition_shape(segments.last)
        candidates(name.split("::").last).lazy.select do |path|
          plausible?(path, segments, shape) && constants_in(path).defines?(name)
        end
      end

      private

      def full(path) = File.join(@root, path)

      def stamp_of(path)
        stat = File.stat(full(path))
        [stat.mtime, stat.size, stat.ino] if stat.file?
      rescue SystemCallError
        nil
      end

      def parse(path)
        result = @parse.call(full(path))
        return unparseable(path, result.errors.first) unless result.errors.empty?

        collector = Collector.new
        result.value.accept(collector)
        FileConstants.new(path:, status: :parsed, names: collector.names, error: nil)
      end

      def unparseable(path, error)
        FileConstants.new(path:, status: :unparseable, names: [],
                          error: "#{error.message} (line #{error.location.start_line})")
      end

      def candidates(short)
        named, others = files.partition { |path| File.basename(path, @extension).delete("_").casecmp?(short) }
        named + others
      end

      def files
        @source_roots.flat_map do |root|
          Dir.glob("**/*#{@extension}", base: full(root)).sort.map { |path| File.join(root, path) }
        end
      end

      # Whatever the collector would index: `class Name`, `module Name`,
      # `class Outer::Name`, `Name =` or `Name ||=` that is not `==`, `=~` or
      # `=>`, and a target of `Name, Other = ...`. The bytes are read without
      # an encoding, so the name's edges are byte lookarounds: `\b` counts a
      # UTF-8 byte as a non-word character and could never close `Café`.
      def definition_shape(short)
        name = "(?<!#{WORD})#{Regexp.escape(short)}(?!#{WORD})"
        opened = "\\b(?:class|module)\\s+(?:[A-Za-z0-9_:\\x80-\\xff]*::)?#{name}"
        assigned = "#{name}\\s*(?:\\|\\|)?=(?![=~>])"
        targeted = "#{name}\\s*,[^\\n=]*=(?![=~>])"
        Regexp.new("(?:#{opened})|(?:#{assigned})|(?:#{targeted})".b, Regexp::NOENCODING)
      end

      def plausible?(path, segments, shape)
        bytes = File.binread(full(path))
        segments.all? { |segment| bytes.include?(segment) } && shape.match?(bytes)
      rescue SystemCallError
        false
      end
    end
  end
end
