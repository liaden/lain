# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): searches source for an ast-grep STRUCTURAL pattern,
    # not a text/regex one -- `$RECV.save` matches the call node and skips the
    # same string inside a comment or a `"..."` literal, which {Grep} cannot
    # tell apart. Built on {Structural::Matcher}; never touches
    # `Lain::Ext::AstGrep` directly, matching the seam {Structural::Matcher}'s
    # own doc describes.
    #
    # A caller supplies either a raw `pattern` (ast-grep metavariable syntax,
    # e.g. `"def $NAME($$$A)"`) or a `query` naming one of
    # {Structural::Patterns::CATALOG}'s named lookups (optionally filled with a
    # literal via `name`, e.g. `query: "method_call", name: "save"`). A named
    # query may expand to several templates (a receiver form and a bare form),
    # all of which run and merge -- the model asks "who calls #save" once, not
    # twice.
    #
    # A malformed pattern, an unknown query, or an unsupported language are
    # reported as an error {Tool::Result}, never a raise: same discipline as
    # {Grep}'s invalid-regex handling.
    class AstSearch < Tool
      # Same rationale and same number as {Grep::MAX_MATCHES}: capped, not
      # silently truncated -- {#format_matches} says so in the body.
      MAX_MATCHES = 200

      # File extensions searched per language, so a directory walk parses only
      # the files that could plausibly be that language -- mirrors Joel's `ag
      # rb` helper filtering to `*.rb` rather than letting a `.py` file get fed
      # to the Ruby grammar. Extend as {Structural::Matcher::SUPPORTED_LANGUAGES}
      # grows real callers.
      EXTENSIONS = {
        ruby: %w[rb],
        rust: %w[rs],
        python: %w[py],
        typescript: %w[ts tsx],
        javascript: %w[js jsx]
      }.freeze

      # The wire shape: a required language and path, plus EITHER a raw
      # `pattern` OR a catalog `query` (with an optional `name` to fill it) --
      # {#perform} enforces "exactly one", since the schema itself cannot
      # express that either-or.
      class Input < Tool::Input
        field :pattern, :string,
              description: "An ast-grep structural pattern, e.g. \"def $NAME($$$A)\" " \
                           "or \"$RECV.save\". Give this OR query, not both."
        field :query, :string,
              description: "A named catalog query instead of a raw pattern: one of " \
                           "method_def, class_def, subclass_of, mixin, instance_var, " \
                           "method_call. Give this OR pattern, not both."
        field :name, :string,
              description: "A literal to fill the catalog query's metavariable, e.g. " \
                           "name: \"save\" with query: \"method_call\" finds calls to " \
                           "#save specifically. Only meaningful together with query."
        field :language, :string,
              description: "The source language: one of #{Structural::Matcher::SUPPORTED_LANGUAGES.join(", ")}.",
              required: true
        field :path, :string,
              description: "File or directory to search. A directory is searched " \
                           "recursively, restricted to that language's file extensions.",
              required: true
      end

      input_model Input

      def name = "ast_search"

      def description
        "Searches source code for an ast-grep STRUCTURAL pattern (not text/regex) " \
          "-- matches syntax, so a hit inside a comment or a string literal never " \
          "counts. Give either a raw `pattern` (ast-grep metavariable syntax) or a " \
          "named `query` from the built-in catalog. Returns file:line locations plus " \
          "the matched line and any named captures. Given a directory, searches " \
          "recursively, restricted to that language's files. Output is capped at " \
          "#{MAX_MATCHES} matches; a capped result says so explicitly. No matches is " \
          "an ok, explicit result, not an error."
      end

      protected

      def perform(input, _invocation)
        problem = problem_with(input)
        return Tool::Result.error(problem) if problem

        language = input.language.downcase.to_sym
        patterns = resolve_patterns(input, language)
        matches = deduplicate(search(input.path, language, patterns)).first(MAX_MATCHES + 1)
        Tool::Result.ok(RESULT_FORMATTER.call(matches, patterns:, path: input.path))
      rescue Structural::Matcher::BadPattern, Structural::Matcher::UnknownLanguage, Structural::Patterns::Unknown => e
        Tool::Result.error(e.message)
      end

      private

      def problem_with(input)
        return "no such file or directory: #{input.path}" unless File.exist?(input.path)
        return "not readable: #{input.path}" unless File.readable?(input.path)
        return "give exactly one of pattern or query, not both" if present?(input.pattern) && present?(input.query)
        unless present?(input.pattern) || present?(input.query)
          return "give one of pattern (a raw ast-grep pattern) or query (a catalog name)"
        end

        nil
      end

      def present?(value)
        !value.nil? && !value.empty?
      end

      def resolve_patterns(input, language)
        return [input.pattern] unless input.query

        args = input.name ? { name: input.name } : {}
        Structural::Patterns.fetch(language, input.query.to_sym, **args)
      end

      # A multi-template query overlaps itself: a `method_call` runs a receiver
      # form (`$RECV.save`) AND a bare form (`save`), and the bare form matches
      # the `save` identifier INSIDE the receiver call too -- so a single call
      # site would otherwise be reported twice, burning the cap. Collapse to one
      # row per (file, line), grep-family granularity; first wins, and since the
      # receiver template runs first, the kept row is the one carrying the RECV
      # capture. Lazy + stateful so it composes with the MAX_MATCHES+1 cap.
      def deduplicate(matches)
        seen = Set.new
        matches.lazy.select { |label, line, _text, _captures| seen.add?([label, line]) }
      end

      # An Enumerator, for the same reason as {Grep#search}: the MAX_MATCHES+1
      # cap in {#perform} stops walking the moment it has enough, rather than
      # matching every file under `path` before discarding most of the result.
      def search(path, language, patterns)
        root = path if File.directory?(path)
        matcher = Structural::Matcher.new
        Enumerator.new do |yielder|
          files_under(path, language).each do |file|
            label = root ? file.delete_prefix("#{root}/") : file
            each_structural_match(matcher, file, language, patterns) do |line_no, text, captures|
              yielder << [label, line_no, text, captures]
            end
          end
        end
      end

      def files_under(path, language)
        return [path] if File.file?(path)

        extensions = EXTENSIONS[language]
        Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
           .reject { |entry| skip?(entry) }
           .select { |entry| File.file?(entry) }
           .select { |entry| language_file?(entry, extensions) }
           .sort
      end

      # No entry in {EXTENSIONS} (a language {Structural::Matcher} supports but
      # this tool has not yet been told the extension for) falls back to
      # searching every file, rather than silently searching none.
      def language_file?(entry, extensions)
        return true unless extensions

        extensions.include?(File.extname(entry).delete_prefix("."))
      end

      # Matches {Grep#skip?}: "." and ".." and anything under ".git" are never
      # content worth searching.
      def skip?(entry)
        entry.split("/").intersect?(%w[. .. .git])
      end

      def each_structural_match(matcher, file, language, patterns)
        source = File.read(file)
        patterns.each do |pattern|
          matcher.match(source:, language:, pattern:).each do |m|
            yield(m.line, line_text(source, m.line), m.captures)
          end
        end
      rescue ArgumentError, SystemCallError, IOError
        # Invalid encoding (binary content) or a file that vanished/denies read
        # between the walk and here -- skipped silently, same as
        # {Grep#each_matching_line}. A {Structural::Matcher::BadPattern} is a
        # DIFFERENT class and is deliberately NOT rescued here: it must escape
        # to {#perform}'s rescue, naming the bad pattern, not be swallowed as
        # if this file were merely unreadable.
        nil
      end

      def line_text(source, line_no)
        source.lines[line_no - 1]&.chomp.to_s
      end

      # Renders a lazily-capped match list into the tool's result body: the
      # truncation disclosure and the capture rendering are one cohesive
      # responsibility, pulled out so {AstSearch} itself stays under
      # Metrics/ClassLength (CLAUDE.md: extract a collaborator, never loosen a
      # Metrics cop). Stateless past its one `max_matches` policy value, so a
      # single frozen instance is shared rather than built per call.
      class ResultFormatter
        def initialize(max_matches:)
          @max_matches = max_matches
          freeze
        end

        def call(matches, patterns:, path:)
          return "no matches for #{patterns.join(" / ").inspect} under #{path}" if matches.empty?

          capped = matches.size > @max_matches
          lines = matches.first(@max_matches).map { |match| format_line(*match) }
          lines << "... capped at #{@max_matches} matches" if capped
          lines.join("\n")
        end

        private

        def format_line(file, line_no, text, captures)
          return "#{file}:#{line_no}:#{text}" if captures.empty?

          rendered = captures.map { |k, v| "#{k}=#{v.inspect}" }.join(", ")
          "#{file}:#{line_no}:#{text} {#{rendered}}"
        end
      end

      RESULT_FORMATTER = ResultFormatter.new(max_matches: MAX_MATCHES).freeze
      private_constant :ResultFormatter, :RESULT_FORMATTER
    end
  end
end
