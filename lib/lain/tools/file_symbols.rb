# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): a file's SYMBOL TABLE -- its role-tagged definitions
    # (namespace/class/method/function/interface/type) and reference occurrences
    # -- read structurally from the parsed syntax tree.
    #
    # This is the raw-tree-sitter counterpart to CodeOutline's ast-grep pattern
    # catalog: instead of a fixed set of metavariable templates, it runs lain's
    # OWN hand-authored role query (Structural::Queries) through Ext::TreeSitter,
    # whose captures bind the identifier node DIRECTLY to a role. That richer
    # query buys named ROLES (a `definition.interface` vs a `definition.class`)
    # and REFERENCES (call sites), which the pattern catalog does not model.
    #
    # Because matching is structural, an identifier that only APPEARS inside a
    # comment or a string literal is never reported -- the whole point next to a
    # regex outline. Nesting is deliberately flat: each entry carries only its
    # own line, ordered by position; a real scope tree is a separate concern.
    class FileSymbols < Tool
      # The wire shape: a file path plus the language to parse it as.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to read.", required: true
        field :language, :string,
              description: "Source language: one of ruby, typescript, rust " \
                           "(python is not yet supported).",
              required: true
      end

      input_model Input

      def name = "file_symbols"

      def description
        "Lists a file's symbols -- its definitions (namespaces, classes, " \
          "methods, functions, interfaces, type aliases), each tagged with a " \
          "role and 1-based line, plus reference occurrences such as call " \
          "sites. Matching is structural (a tree-sitter query over the parsed " \
          "syntax tree), so an identifier that only appears in a comment or a " \
          "string literal is never reported. Supports ruby, typescript, and " \
          "rust. Returns an error result if the path does not exist, is a " \
          "directory, cannot be read, or the language is unsupported."
      end

      protected

      def perform(input, _invocation)
        path = input.path
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        language = input.language.downcase.to_sym
        source = File.read(path)
        Tool::Result.ok(render(occurrences(source, language)))
      rescue Structural::Queries::Unsupported, Ext::TreeSitter::BadQuery => e
        Tool::Result.error(e.message)
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not read #{path}: #{e.message}")
      end

      private

      # Shared with ReadFile/CodeOutline: a missing path, a directory, or an
      # unreadable file is a reasonable question the model asked, so it earns an
      # error Result it can act on rather than a raise.
      def problem_with(path)
        return "no such file: #{path}" unless File.exist?(path)
        return "is a directory, not a file: #{path}" if File.directory?(path)
        return "file is not readable: #{path}" unless File.readable?(path)

        nil
      end

      # One captured symbol: a 1-based line, its kind ("definition"/"reference"),
      # the role within that kind ("method", "call", ...), and the identifier
      # text. The capture name Ext::TreeSitter returns is "<kind>.<role>", which
      # split() turns into exactly these two halves. Named Occurrence, not
      # Symbol, to avoid shadowing Ruby's core ::Symbol inside this class.
      Occurrence = Data.define(:line, :kind, :role, :name)
      private_constant :Occurrence

      def occurrences(source, language)
        query = Structural::Queries.fetch(language)
        Ext::TreeSitter.query(source, language.to_s, query).map do |capture|
          kind, role = capture.fetch("name").split(".", 2)
          Occurrence.new(line: line_for(source, capture.fetch("start")), kind:, role:, name: capture.fetch("text"))
        end
      end

      # 1-based line from a byte offset -- the same counting Structural::Matcher
      # does: `.b` keeps a boundary that lands mid multi-byte character from
      # raising, since a newline is one ASCII byte regardless of encoding tag.
      def line_for(source, start_byte)
        source.byteslice(0, start_byte).b.count("\n") + 1
      end

      def render(occurrences)
        definitions, references = occurrences.partition { |occurrence| occurrence.kind == "definition" }
        [section("DEFINITIONS", definitions), section("REFERENCES", references)].join("\n\n")
      end

      def section(heading, occurrences)
        rows = occurrences.sort_by(&:line).map do |occurrence|
          "  L#{occurrence.line}  #{occurrence.role}  #{occurrence.name}"
        end
        ([heading] + (rows.empty? ? ["  (none)"] : rows)).join("\n")
      end
    end
  end
end
