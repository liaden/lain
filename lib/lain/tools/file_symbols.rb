# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): a file's SYMBOL TABLE -- its role-tagged definitions
    # (namespace/class/method/function/interface/type) and reference occurrences
    # -- read structurally from the parsed syntax tree.
    #
    # A raw tree-sitter query, run through Ext::TreeSitter, whose captures bind
    # the identifier node DIRECTLY to a role -- unlike an ast-grep pattern
    # catalog matched shape-only, this buys named ROLES and REFERENCES that a
    # plain structural match does not model.
    #
    # Because matching is STRUCTURAL, an identifier that only appears inside a
    # comment or a string literal is never reported. Nesting is deliberately
    # flat: each entry carries only its own line, ordered by position.
    class FileSymbols < Tool
      include Tool::FileTarget

      # The only tool here with TWO bounds. DEFINITIONS and REFERENCES are
      # separate sections with separate true counts, so one shared bound taken
      # before the partition would let a definition-heavy file spend the whole
      # budget and return an empty REFERENCES heading -- a partial answer that
      # reads like a complete one.
      #
      # Definitions are capped at 200, measured over this tool's own output: a
      # role query finds MORE than shape-matching alone would, so the densest
      # DEFINITIONS section over the repo's 647 `lib/**/*.rb` is 135, where a
      # plain structural pattern match (matching shape only, no role capture)
      # over the same file tops out at 80. 200 sits well above either.
      #
      # References get 500 because call sites outnumber definitions, and the
      # MULTIPLE is the number: over the 182 `lib/` files with more than 20
      # definitions, the reference:definition ratio has a median of 2.45 and a
      # maximum of 4.26. 500/200 is 2.5, so the two sections fill at about the
      # same rate on real source. One shared cap would truncate references on
      # ordinary files while the definition section never filled, making the cap
      # a fact about the TOOL rather than about the file.
      #
      # Worst case is the sum: 700 rows at a measured 22.7 B is ~16 KB, which is
      # {Grep}'s ~14 KB band rather than a second helping of it.
      DEFINITIONS_BOUND = Tool::Bounds::Enumeration.new(limit: 200, unit: "definitions")
      REFERENCES_BOUND = Tool::Bounds::Enumeration.new(limit: 500, unit: "references")

      # Refused rather than cut past this: the two sections carry their own
      # counts, so a cut would leave one of them reading complete.
      BOUND = Tool::Bounds::Artifact.new(limit: Tool::Bounds::CEILINGS.fetch("file_symbols"))

      NARROWER = ["grep the file for the names you need", "ast_search it for one kind of construct"].freeze

      # Built FROM the two bounds rather than written out beside them, so the
      # numbers the model is told and the numbers enforced cannot drift.
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
      # resolve the path, then one file, run through Ext::TreeSitter.query,
      # documented stateless. No Session write, no chdir, no process-global
      # state.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        path = target(invocation, input.path)
        problem = problem_with(path, expecting: :file)
        return Tool::Result.error(problem) if problem

        language = input.language.downcase.to_sym
        # `EncodingError` rides the unreadable-file arm: the ext refuses a
        # source it would have to transcode, because the byte offsets this tool
        # turns into line numbers would then index a copy the caller never
        # sees. To the model that is the same answer as any other "this file
        # cannot be read", which is why it is handed to {#failing} rather than
        # rescued apart.
        failing("read", path, EncodingError) { bounded(path, render(occurrences(utf8_source(path), language))) }
      rescue Structural::Queries::Unsupported, Structural::Queries::Missing, Ext::TreeSitter::BadQuery => e
        Tool::Result.error(e.message)
      end

      private

      def bounded(path, table)
        return Tool::Result.ok(table) if BOUND.admits?(table.bytesize)

        BOUND.refusal(subject: "the symbol table of #{path}", size: table.bytesize, narrower: NARROWER)
      end

      # A 1-based line, its kind, the role within that kind, and the identifier
      # text. Ext::TreeSitter returns a capture name of "<kind>.<role>", which
      # split() turns into exactly these two halves. Named Occurrence rather
      # than Symbol, to avoid shadowing Ruby's core ::Symbol in this class.
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
      # is made the tiebreak explicitly. The instability is real and not
      # theoretical: measured over 300 lines of `class K#{i}; def m#{i}; end;
      # end`, a plain structural pattern match's own within-line order FLIPS
      # partway down the file (`{["def","class"] => 66, ["class","def"] => 34}`
      # at that fixture's tie width) -- this tool's own `occurrences` happens
      # not to produce that flip on real source (see the spec's own note), but
      # the mechanism defends against the same instability regardless.
      def ordered(occurrences)
        occurrences.each_with_index.sort_by { |occurrence, index| [occurrence.line, index] }.map(&:first)
      end
    end
  end
end
