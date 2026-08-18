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
      # A symbol table is an ENUMERATION under {Tool::Bounds}' stated boundary,
      # and it is the only tool here with TWO of them. DEFINITIONS and
      # REFERENCES are separate sections with separate true counts, so one
      # shared bound taken before the partition would let a definition-heavy
      # file spend the whole budget and return an empty REFERENCES heading --
      # a partial answer that reads like a complete one, which is precisely the
      # failure the boundary exists to prevent. Two bounds, two notices, two
      # counts.
      #
      # Definitions take {CodeOutline::BOUND}'s 200: it is the same question
      # with roles attached. The measurement is this tool's own, not that one's
      # -- a role query finds more than a pattern catalog does, so the densest
      # DEFINITIONS section over the repo's 647 `lib/**/*.rb` is **135**
      # (`lib/lain/review/docent.rb`) where the same file outlines at 80. 200
      # clears both.
      #
      # References get 500 because call sites outnumber definitions, and the
      # multiple is the number: measured over the 182 `lib/` files with more
      # than 20 definitions, the reference:definition ratio has a MEDIAN of
      # **2.45** and a maximum of 4.26. 500/200 is 2.5, so the two sections fill
      # at about the same rate on real source -- which is the property being
      # bought. One shared cap would truncate references on ordinary files while
      # the definition section never filled, making the cap a fact about the
      # tool rather than about the file.
      #
      # The anchor is denominated per OBSERVATION, and this is the only tool
      # here that emits two sections, so its worst case is the sum: 700 rows at
      # a measured 22.7 B (110 `lib/` files of over 100 rows) is **~16 KB**,
      # which is {Grep}'s ~14 KB band rather than a second helping of it.
      DEFINITIONS_BOUND = Tool::Bounds::Enumeration.new(limit: 200, unit: "definitions")
      REFERENCES_BOUND = Tool::Bounds::Enumeration.new(limit: 500, unit: "references")

      # Built from the two bounds rather than written out beside them, so the
      # numbers the model is told and the numbers enforced cannot drift. It
      # lives here, next to what it reads, instead of inside {#description}:
      # two bounds take two clauses, and the sentence is the only part of that
      # string that is derived rather than prose.
      CAP_NOTE = "Each section caps separately, at #{DEFINITIONS_BOUND.limit} definitions and " \
                 "#{REFERENCES_BOUND.limit} references; a capped section says so and names its true count."
                 .freeze
      private_constant :CAP_NOTE

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
          "rust. #{CAP_NOTE} Returns an error result if the path does not " \
          "exist, is a directory, cannot be read, or the language is " \
          "unsupported."
      end

      # Audited: reads Session#worker_env.cwd (a value read, not a mutation) to
      # resolve the path, then one file (File.read), run through
      # Ext::TreeSitter.query -- documented stateless (treesitter.rs: "Every
      # call is STATELESS", no ext-side index handle to keep). No Session write,
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
        Tool::Result.ok(render(occurrences(source, language)))
      rescue Structural::Queries::Unsupported, Structural::Queries::Missing, Ext::TreeSitter::BadQuery => e
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
        query = Structural::Queries.fetch(language, :symbols)
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
        [section("DEFINITIONS", definitions, DEFINITIONS_BOUND),
         section("REFERENCES", references, REFERENCES_BOUND)].join("\n\n")
      end

      # The cap notice lands FLUSH LEFT among two-space-indented rows, and that
      # is left as it is: a row that is not a symbol should not be shaped like
      # one, and {Tool::Bounds::Enumeration#cap} owns the notice's format so
      # that every adopting tool discloses in the same words.
      def section(heading, occurrences, bound)
        rows = bound.cap(ordered(occurrences).map do |occurrence|
          "  L#{occurrence.line}  #{occurrence.role}  #{occurrence.name}"
        end)
        ([heading] + (rows.empty? ? ["  (none)"] : rows)).join("\n")
      end

      # The index in the sort key is not decoration: `sort_by` is NOT stable in
      # CRuby, and ties are the COMMON case here rather than the odd one --
      # every chained call puts several references on one line. Under a bound an
      # unstable tie stops being cosmetic and decides which occurrences exist at
      # all, so collection order (which is the query's, which is the document's)
      # is made the tiebreak explicitly. {CodeOutline#render} carries the
      # measurement that shows the instability is real and not theoretical.
      def ordered(occurrences)
        occurrences.each_with_index.sort_by { |occurrence, index| [occurrence.line, index] }.map(&:first)
      end
    end
  end
end
