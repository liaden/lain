# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): searches source for an ast-grep STRUCTURAL pattern
    # rather than a text/regex one -- `$RECV.save` matches the call node and
    # skips the same string inside a comment or a `"..."` literal, which {Grep}
    # cannot tell apart.
    #
    # A caller supplies either a raw `pattern` or a `query` naming one of
    # {Structural::Patterns::CATALOG}'s lookups, optionally filled with a
    # literal via `name`. A named query may expand to several templates -- a
    # receiver form and a bare form -- all of which run and MERGE, so the model
    # asks "who calls #save" once rather than twice.
    #
    # A malformed pattern, an unknown query, or an unsupported language is
    # reported as an error {Tool::Result}, never a raise.
    class AstSearch < Tool
      include Tool::FileTarget

      # Same rationale and same number as {Grep::MAX_MATCHES}: capped, not
      # silently truncated -- {#format_matches} says so in the body.
      MAX_MATCHES = 200

      # The same walk-cap {Grep} shares: one row past the limit is all
      # {#capped_matches} ever pulls, and {ResultFormatter} renders its
      # trailer from this instance so the wording stays byte-identical to
      # {Grep}'s without either file re-deriving the other's number.
      WALK_CAP = Tool::Bounds::WalkCap.new(limit: MAX_MATCHES)

      # So a directory walk parses only the files that could plausibly be that
      # language, rather than feeding a `.py` file to the Ruby grammar.
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

      # Audited: reads Session#worker_env.cwd (a value read, not a mutation) to
      # resolve the path, then the filesystem, running each match through a
      # fresh per-call Structural::Matcher, documented stateless. No Session
      # write, no chdir, no process-global state.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        # The FILESYSTEM locator, matching {Grep}: every MODEL-FACING mention
        # of the path keeps the model's original spelling instead. An ERROR is
        # the one exception, naming the resolved path, because "where did it
        # actually look" is the whole content of that message.
        path = target(invocation, input.path)
        # The target rules first and the input-shape rules second, which is the
        # order this tool has always refused in.
        problem = problem_with(path, expecting: :either) || badly_shaped(input)
        return Tool::Result.error(problem) if problem

        language = input.language.downcase.to_sym
        patterns = resolve_patterns(input, language)
        found = capped_matches(path, input.path, language, patterns)
        Tool::Result.ok(RESULT_FORMATTER.call(found, patterns:, path: input.path))
      # `EncodingError` rides with the rest despite NOT being a Lain::Error:
      # the ext refuses a source it would have to transcode, and Ruby's own
      # class is what comes back. {#each_structural_match} has already named the
      # file, so the message needs no decoration.
      rescue Structural::Matcher::BadPattern, Structural::Matcher::UnknownLanguage,
             Structural::Patterns::Unknown, EncodingError => e
        Tool::Result.error(e.message)
      end

      private

      # {WALK_CAP} owns the one-more-than-the-limit pull, so this stays a
      # single delegation -- the discipline of parsing no file past what the
      # cap needs lives on {Tool::Bounds::WalkCap#apply}, not here.
      def capped_matches(path, display, language, patterns)
        WALK_CAP.apply(deduplicate(search(path, display, language, patterns)))
      end

      # The two rules {Tool::FileTarget} cannot own, because they are about
      # this tool's INPUT rather than about its target.
      def badly_shaped(input)
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

      # An Enumerator, for {Grep#search}'s reason: the MAX_MATCHES+1 cap stops
      # walking the moment it has enough, rather than matching every file under
      # `path` before discarding most of the result.
      #
      # A DIRECTORY target labels each hit relative to the walked root; a
      # SINGLE-FILE target labels its hits with the model's own spelling, so a
      # relative `foo.rb` stays `foo.rb:1:` rather than leaking the resolved
      # absolute path.
      def search(path, display, language, patterns)
        root = path if File.directory?(path)
        matcher = Structural::Matcher.new
        Enumerator.new do |yielder|
          files_under(path, language).each do |file|
            label = root ? file.delete_prefix("#{root}/") : display
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

      # A language with no {EXTENSIONS} entry falls back to searching EVERY
      # file, rather than silently searching none.
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
        source = utf8_source(file)
        patterns.each do |pattern|
          matcher.match(source:, language:, pattern:).each do |m|
            yield(m.line, line_text(source, m.line), m.captures)
          end
        end
      rescue ArgumentError, SystemCallError, IOError
        # A file that vanished or denies read between the walk and here --
        # skipped silently, same as {Grep#each_matching_line}. A
        # {Structural::Matcher::BadPattern} is a DIFFERENT class and is
        # deliberately NOT rescued here: it must escape to {#perform}'s rescue,
        # naming the bad pattern, not be swallowed as if this file were merely
        # unreadable.
        nil
      rescue EncodingError => e
        # NOT a silent skip. A `.rb` file whose bytes are not valid UTF-8 is
        # anomalous enough to report, and the alternative reads to the model as
        # "your pattern matched nothing" -- indistinguishable from a real
        # no-match. Re-raised only to attach the FILE, which {#perform}'s
        # rescue is too far from the walk to know.
        raise EncodingError, "#{file}: #{e.message}"
      end

      def line_text(source, line_no)
        source.lines[line_no - 1]&.chomp.to_s
      end

      # Renders an already-capped match list into the tool's result body: the
      # truncation disclosure and the capture rendering are one cohesive
      # responsibility, pulled out so {AstSearch} itself stays under
      # Metrics/ClassLength (CLAUDE.md: extract a collaborator, never loosen a
      # Metrics cop). Stateless past its one `walk_cap` policy value, so a
      # single frozen instance is shared rather than built per call.
      class ResultFormatter
        def initialize(walk_cap:)
          @walk_cap = walk_cap
          freeze
        end

        # `found` is {#capped_matches}'s already-capped {Tool::Bounds::Found}
        # -- the cap itself is `@walk_cap`'s job, not this method's.
        def call(found, patterns:, path:)
          return "no matches for #{patterns.join(" / ").inspect} under #{path}" if found.rows.empty?

          lines = found.rows.map { |match| format_line(*match) }
          lines << @walk_cap.notice("matches") if found.capped
          lines.join("\n")
        end

        private

        def format_line(file, line_no, text, captures)
          return "#{file}:#{line_no}:#{text}" if captures.empty?

          rendered = captures.map { |k, v| "#{k}=#{v.inspect}" }.join(", ")
          "#{file}:#{line_no}:#{text} {#{rendered}}"
        end
      end

      RESULT_FORMATTER = ResultFormatter.new(walk_cap: WALK_CAP).freeze
      private_constant :ResultFormatter, :RESULT_FORMATTER
    end
  end
end
