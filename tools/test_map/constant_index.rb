# frozen_string_literal: true

require_relative "git"
require "prism"

module TestMap
  # Answers which lib and spec files mention a constant a lib file defines,
  # by name alone: it never loads lain, which may not be compiled yet.
  class ConstantIndex
    # The spellings Zeitwerk's inflector cannot derive from a path (lib/lain.rb).
    INFLECTIONS = { "cli" => "CLI", "http" => "HTTP", "qa" => "QA", "tty" => "TTY" }.freeze

    # Swappable so a spec can supply old sources without a repository.
    class GitReader
      def initialize(root:)
        @root = root
      end

      # Nil only for a path the tree lacks (a file the change adds); a tree git cannot read raises.
      def show(tree, path)
        TestMap::Git.run("show", "#{tree}:#{path}", repo: @root) if present?(tree, path)
      end

      private

      def present?(tree, path)
        !TestMap::Git.run("ls-tree", "--name-only", tree, "--", path, repo: @root).empty?
      end
    end

    # Collects the constants one source file defines and the names its
    # references could resolve to, given the lexical namespaces they sit in.
    class Scan < Prism::Visitor
      attr_reader :defined, :referenced

      def self.of(source)
        new.tap { |scan| scan.visit(Prism.parse(source).value) }
      end

      def initialize
        super
        @defined = Set.new
        @referenced = Set.new
        @nesting = []
      end

      def visit_class_node(node)
        visit(node.superclass) if node.superclass
        enter(node)
      end

      def visit_module_node(node)
        enter(node)
      end

      def visit_constant_write_node(node)
        @defined << qualify(node.name.to_s)
        super
      end

      def visit_constant_or_write_node(node)
        @defined << qualify(node.name.to_s)
        super
      end

      def visit_constant_path_write_node(node)
        @defined << qualify(node.target.full_name.delete_prefix("::"))
        super
      end

      def visit_constant_target_node(node)
        @defined << qualify(node.name.to_s)
        super
      end

      def visit_constant_read_node(node)
        reference(node.name.to_s)
      end

      def visit_constant_path_node(node)
        reference(node.full_name.delete_prefix("::"))
        super
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        super
      end

      private

      def enter(node)
        name = qualify(node.constant_path.full_name.delete_prefix("::"))
        @defined << name
        @nesting.push(name)
        visit(node.body) if node.body
      ensure
        @nesting.pop
      end

      def qualify(name) = [@nesting.last, name].compact.join("::")

      def reference(name)
        @referenced << name
        @nesting.each { |scope| @referenced << "#{scope}::#{name}" }
      end
    end

    def self.for(root:, old_tree:)
      new(root:, reader: GitReader.new(root:), old_tree:)
    end

    def initialize(root:, reader:, old_tree:)
      @root = root
      @reader = reader
      @old_tree = old_tree
      @scans = working_sources.transform_values { |source| Scan.of(source) }
      @referrers = invert_references
    end

    def dependents(path)
      definitions(path).each_with_object(Set.new) do |name, found|
        found.merge(@referrers.fetch(name, []))
      end.delete(path)
    end

    private

    def working_sources
      Dir.glob(["lib/**/*.rb", "spec/**/*_spec.rb"], base: @root).sort.to_h do |path|
        [path, File.read(File.join(@root, path))]
      end
    end

    def invert_references
      @scans.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |(path, scan), index|
        scan.referenced.each { |name| index[name] << path }
      end
    end

    def definitions(path)
      return Set.new unless path.start_with?("lib/")

      Set[path_constant(path)].merge(@scans[path]&.defined.to_a, old_definitions(path))
    end

    def old_definitions(path)
      source = @old_tree && @reader.show(@old_tree, path)
      source ? Scan.of(source).defined.to_a : []
    end

    def path_constant(path)
      parts = path.delete_prefix("lib/").delete_suffix(".rb").split("/")
      parts.map { |part| INFLECTIONS.fetch(part) { part.split("_").map(&:capitalize).join } }.join("::")
    end
  end
end
