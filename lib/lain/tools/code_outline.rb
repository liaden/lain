# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): a FIXED set of catalog queries -- Structural::Patterns'
    # `:class_def` and `:method_def` -- run over ONE file through
    # Structural::Matcher. This is not a new mechanism; T2's catalog and T3's
    # Matcher already exist, so this tool is only the read-one-file-and-format
    # wiring over them.
    #
    # Because matching is structural (an ast-grep pattern against a parsed
    # syntax tree, not a line of text), an identifier that only APPEARS inside
    # a comment or a string literal never counts as a hit -- the whole point
    # next to a regex-based outline, which cannot tell `class Foo` the
    # definition from `# class Foo` the comment.
    #
    # Nesting (a class inside a module) is deliberately NOT reconstructed:
    # each hit carries only its own line, so the outline is flat and
    # line-ordered rather than a tree. Recovering real lexical scope needs a
    # scope walk over the CST (tree-sitter `locals`), which is T8's job, not
    # this card's.
    class CodeOutline < Tool
      # The wire shape: a file path plus the language to parse it as.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to outline.", required: true
        field :language, :string,
              description: "Source language, e.g. \"ruby\" " \
                           "(see Lain::Structural::Matcher::SUPPORTED_LANGUAGES).",
              required: true
      end

      input_model Input

      def name = "code_outline"

      def description
        "Lists a file's module/class definitions and methods, one per line, " \
          "each tagged with its 1-based line number and ordered by position " \
          "in the file. Matching is structural (an ast-grep pattern over the " \
          "parsed syntax tree), so an identifier that only appears inside a " \
          "comment or a string literal is never reported. Returns an error " \
          "result if the path does not exist, is a directory, cannot be " \
          "read, or the language is unsupported."
      end

      protected

      def perform(input, _invocation)
        path = input.path
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        language = input.language.downcase.to_sym
        source = File.read(path)
        Tool::Result.ok(render(outline_entries(source, language)))
      rescue Structural::Matcher::UnknownLanguage, Structural::Patterns::Unknown => e
        # Patterns.fetch raises Unknown for a language its own catalog has no
        # queries for (today, anything but :ruby) -- BEFORE the Matcher ever
        # gets a chance to raise its own UnknownLanguage for one outside its
        # (larger) supported set. Both spellings mean the same thing to this
        # tool's caller: this language cannot be outlined, so both fold into
        # one error Result.
        Tool::Result.error(e.message)
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not read #{path}: #{e.message}")
      end

      private

      def problem_with(path)
        return "no such file: #{path}" unless File.exist?(path)
        return "is a directory, not a file: #{path}" if File.directory?(path)
        return "file is not readable: #{path}" unless File.readable?(path)

        nil
      end

      # One structural hit: a 1-based line, the literal keyword to print
      # ("module"/"class" from which `:class_def` template matched,
      # "def"/"def self." from which `:method_def` template matched -- so the
      # outline echoes the source's own spelling rather than inventing a
      # generic "method" tag), and the captured name.
      Entry = Data.define(:line, :label, :name)
      private_constant :Entry

      def outline_entries(source, language)
        matcher = Structural::Matcher.new
        class_entries(matcher, source, language) + method_entries(matcher, source, language)
      end

      def class_entries(matcher, source, language)
        Structural::Patterns.fetch(language, :class_def).flat_map do |pattern|
          label = pattern.start_with?("module") ? "module" : "class"
          matcher.match(source:, language:, pattern:).map do |match|
            Entry.new(line: match.line, label:, name: match.captures.fetch("N"))
          end
        end
      end

      def method_entries(matcher, source, language)
        Structural::Patterns.fetch(language, :method_def).flat_map do |pattern|
          label = pattern.start_with?("def self.") ? "def self." : "def"
          matcher.match(source:, language:, pattern:).map do |match|
            Entry.new(line: match.line, label:, name: match.captures.fetch("NAME"))
          end
        end
      end

      def render(entries)
        entries.sort_by(&:line).map { |e| "L#{e.line}  #{format_entry(e)}" }.join("\n")
      end

      # A label ending in "." (the "def self." singleton-method prefix)
      # already abuts the name with no space in real Ruby syntax; every other
      # label ("module", "class", "def") wants one.
      def format_entry(entry)
        separator = entry.label.end_with?(".") ? "" : " "
        "#{entry.label}#{separator}#{entry.name}"
      end
    end
  end
end
