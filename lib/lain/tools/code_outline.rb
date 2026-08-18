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
      # An outline is an ENUMERATION under {Tool::Bounds}' stated boundary: one
      # row per definition, independent of the rest, so the first N of them are
      # a usable partial answer. It caps and discloses in band.
      #
      # 200, which is {Grep::MAX_MATCHES} taken outright rather than re-derived
      # -- the row is match-shaped and the model already knows that number from
      # `grep` and `ast_search`. It sits well above anything a human writes:
      # measured with THIS tool over all 647 of the repo's `lib/**/*.rb`, the
      # densest outline is **80** definitions (`lib/lain/review/docent.rb`,
      # with `frontend/neovim/rpc_thread.rb` next at 79). So the ceiling binds
      # only on generated or pathological source, which is the case it is here
      # for. At ~23 B a row it costs ~5 KB, under {Glob}'s ceiling, and
      # that asymmetry is right: an outline is per-FILE, so a caller that hits
      # this cap has a narrower question available (`ast_search` for one
      # construct) that a listing's caller does not.
      #
      # Applied after `render`'s by-line sort, never during collection --
      # `class_entries` are gathered before `method_entries`, so a cap taken
      # before the sort would answer a large file with every class and no
      # method while claiming to be an outline of it.
      BOUND = Tool::Bounds::Enumeration.new(limit: 200, unit: "definitions")

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
          "comment or a string literal is never reported. Output is capped at " \
          "#{BOUND.limit} definitions; a capped outline says so and names the " \
          "true count rather than truncating silently. Returns an error " \
          "result if the path does not exist, is a directory, cannot be " \
          "read, or the language is unsupported."
      end

      # Audited: reads Session#worker_env.cwd (a value read, not a mutation) to
      # resolve the path, then one file (File.read), run through a fresh,
      # per-call Structural::Matcher -- documented stateless (astgrep.rs:
      # "Every call is STATELESS", no ext-side index handle). No Session write,
      # no chdir, no process-global state.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        path = resolved_path(input, invocation)
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        language = input.language.downcase.to_sym
        # `encoding:` is not decoration: a bare File.read tags its result with
        # Encoding.default_external, which under a C locale (containers, systemd
        # units) is US-ASCII -- so every ordinary UTF-8 file would come back
        # mislabelled and the ext would refuse it, truthfully but uselessly.
        source = File.read(path, encoding: Encoding::UTF_8)
        Tool::Result.ok(render(outline_entries(source, language)))
      rescue Structural::Matcher::UnknownLanguage, Structural::Patterns::Unknown => e
        # Patterns.fetch raises Unknown for a language its own catalog has no
        # queries for (today, anything but :ruby) -- BEFORE the Matcher ever
        # gets a chance to raise its own UnknownLanguage for one outside its
        # (larger) supported set. Both spellings mean the same thing to this
        # tool's caller: this language cannot be outlined, so both fold into
        # one error Result.
        Tool::Result.error(e.message)
      # `EncodingError` joins the unreadable-file arm rather than earning its
      # own: the ext refuses a source it would have to transcode, because the
      # byte offsets this tool turns into line numbers would then index a copy
      # the caller never sees (ext/lain/src/read_text.rs). To the model that is
      # the same answer as any other "this file cannot be read" -- and it must
      # land here, not escape #call, which no Tool does with a question the
      # model asked.
      rescue SystemCallError, IOError, EncodingError => e
        Tool::Result.error("could not read #{path}: #{e.message}")
      end

      private

      # A relative path resolves against the session's WorkerEnv cwd (Dir.pwd
      # under the default, so byte-identical to a raw File.read); an absolute
      # one is honored as given. Same rule, same shape, as {ReadFile}
      # and {Grep#resolved_path}.
      def resolved_path(input, invocation)
        File.expand_path(input.path, session_of(invocation).worker_env.cwd)
      end

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

      # The index in the sort key is not decoration. `sort_by` is NOT stable in
      # CRuby, and this collection is `class_entries` followed by
      # `method_entries` -- so two definitions sharing ONE line sit far apart in
      # it and quicksort decides which comes first by its own internals, not by
      # anything the language promises. Measured over 300 lines of
      # `class K; def m(); end; end`: the within-line order FLIPS partway down
      # the file (`{["def","class"] => 66, ["class","def"] => 34}`).
      #
      # Before {BOUND} that was cosmetic -- two rows on one line in an odd
      # order. Under a cap it decides which rows EXIST, which is exactly what
      # the cap-after-the-sort rule exists to keep away from accidents. The
      # index makes collection order the tiebreak, so this method's claim to
      # return the file's FIRST definitions is true rather than usually true.
      def render(entries)
        rows = entries.each_with_index
                      .sort_by { |entry, index| [entry.line, index] }
                      .map { |entry, _| "L#{entry.line}  #{format_entry(entry)}" }
        BOUND.cap(rows).join("\n")
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
