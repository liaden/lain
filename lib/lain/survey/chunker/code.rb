# frozen_string_literal: true

module Lain
  module Survey
    module Chunker
      Code = Data.define(:ceiling, :floor, :granularity)

      # Source code chunked at its own definitions, read from the same
      # hand-authored `symbols.scm` queries {Tools::FileSymbols} runs.
      #
      # == The difficulty is the coverage contract, not the definitions
      #
      # A file is not only its definitions. Requires, magic comments, constants,
      # a module body's own statements and the prose between two methods all
      # belong to SOME unit, or they are never shown and marking the file
      # reviewed is a lie. The symbols query names the definitions; the lines
      # between them are this class's whole work.
      #
      # The rule: walk top to bottom and start a new unit at each definition, so
      # everything above the first one is its own unit. Attaching THAT preamble
      # downward is the move that would be wrong -- an edit to a file-level
      # require would clear the mark on a method that did not change.
      #
      # == A COMMENTARY run attaches DOWNWARD, and that is not the same rule
      #
      # A contiguous run of commentary immediately above a definition belongs to
      # the definition it documents. Without this, editing BETA's docstring
      # changes ALPHA's key and leaves BETA's untouched -- the preamble defect
      # rotated 180 degrees, and the commonest edit there is in a codebase whose
      # house style is a paragraph of why above every method.
      #
      # What counts as commentary is PER LANGUAGE, and blank-or-comment is the
      # Ruby-shaped answer. Rust puts attributes between a doc comment and its
      # item and TypeScript puts decorators there, so a blank-or-comment walk
      # stops at `#[inline]` and strands the `///` above it with the previous
      # definition -- 374 definitions in this repository's own Rust are preceded
      # by an attribute line, so it is the common shape and not a corner. The
      # prefixes live in {EXTENSIONS} beside the language they belong to.
      #
      # A require is not commentary, so the preamble rule above still holds: the
      # run stops at the first line that is neither commentary nor blank. A run
      # of blanks alone does NOT attach downward -- the blank line after a
      # method reads as that method's, and moving it would churn every unit
      # boundary for no content.
      #
      # The known gap is the BLOCK comment: `/* */` and JSDoc `/** */` are not
      # recognised, so they stay where they were. Line-prefix matching cannot
      # tell a continuation line from a multiplication, and the doc style in the
      # languages here is `///` and `//`.
      #
      # == What a definition capture actually gives us
      #
      # A start, and no end. The authored queries bind the NAME node
      # (`(method name: (identifier) @definition.method)`) so that a capture
      # carries a role directly, which is what makes them useful to the symbols
      # tool -- and it means a definition's extent is not in the answer. Those
      # files serve production and are deliberately left unchanged, so a
      # definition's unit runs to the line before the NEXT definition's run.
      #
      # Nesting needs no policy for the same reason: identifier captures are
      # points, and points cannot overlap, so `module`, `class` and `def`
      # starts are simply three boundaries in one ordered list. What that costs
      # is granularity -- one one-line unit per nesting level, in every file in
      # this repository -- and {Granularity} is what pays it back.
      #
      # A language with no authored query, a file whose extension names none,
      # and a file whose bytes are not valid UTF-8 all fall to the paragraph
      # floor rather than refusing: a survey that cannot read a `.lua` file at
      # all is worse than one that reads it as prose.
      class Code
        Language = Data.define(:name, :commentary)
        private_constant :Language

        # Extension to language, and to the line prefixes that make a line
        # COMMENTARY in that language. ONE table, because they are one fact
        # about a file type -- and it maps extensions only. Whether lain can
        # actually parse the language is {Structural::Queries}' answer, asked at
        # every call, so dropping a language from its table makes these files
        # fall to the floor instead of raising out of a chunker.
        #
        # Commentary is wider than "comment", and per language, because what
        # sits between a doc comment and the thing it documents differs: Rust
        # puts attributes there and TypeScript decorators. Both belong to the
        # definition below them, and treating them as ordinary code strands the
        # doc comment above them with the PREVIOUS definition.
        EXTENSIONS = {
          ".rb" => Language.new(name: :ruby, commentary: ["#"].freeze),
          ".rake" => Language.new(name: :ruby, commentary: ["#"].freeze),
          ".rs" => Language.new(name: :rust, commentary: ["//", "#[", "#!["].freeze),
          ".ts" => Language.new(name: :typescript, commentary: ["//", "@"].freeze),
          ".tsx" => Language.new(name: :typescript, commentary: ["//", "@"].freeze)
        }.freeze

        DEFINITION = "definition"

        def initialize(ceiling: DEFAULT_CEILING, floor: Paragraphs.new(ceiling:),
                       granularity: Granularity.new)
          super(ceiling: Integer(ceiling), floor:, granularity:)
        end

        # @param path [String] the path the units will carry, and whose
        #   extension chooses the grammar
        # @param source [String] the whole file
        # @return [Array<Unit>] ordered, covering every line exactly once
        def call(path:, source:)
          language = language_for(path)
          return floor.call(path:, source:) if language.nil? || !Chunker.parseable?(source)

          lines = Unit.lines_of(source)
          granularity.coalesce(
            segments(definitions(source, language, lines), lines.size)
              .flat_map { |first, last, label| units(path:, lines:, first_line: first, last_line: last, label:) }
          )
        end

        private

        # Supported is what {Structural::Queries} says it is, never what this
        # table says: one classifier, and disagreement is unrepresentable.
        def language_for(path)
          language = EXTENSIONS[File.extname(path)]
          language if Structural::Queries.languages_for(:symbols).include?(language&.name)
        end

        # `[first_line, last_line, label]` per unit-to-be, tiling the file: the
        # preamble above the first definition, then each definition up to the
        # line before the next.
        def segments(definitions, line_count)
          starts = definitions.map(&:first)
          (preamble(starts.first, line_count) + spans(definitions, starts, line_count))
            .reject { |first_line, last_line, _| last_line < first_line }
        end

        # Everything above the first definition. A file that OPENS with one
        # yields `[1, 0]`, which the caller's reject drops -- an empty range is
        # how "there is no preamble" says itself, rather than a second branch.
        def preamble(first_definition, line_count)
          [[1, (first_definition || (line_count + 1)) - 1, ""]]
        end

        def spans(definitions, starts, line_count)
          definitions.zip(starts.drop(1) + [line_count + 1])
                     .map { |(first_line, label), following| [first_line, following - 1, label] }
        end

        # Definition captures only: a `reference.call` marks a call site, and
        # taking those as boundaries would put a unit at every method call in
        # the file.
        def definitions(source, language, lines)
          captures(source, language)
            .map { |capture| [start_of(capture, source, lines, language), label_for(capture)] }
            .uniq(&:first)
            .sort_by(&:first)
        end

        def captures(source, language)
          query = Structural::Queries.fetch(language.name, :symbols)
          Ext::TreeSitter.query(source, language.name.to_s, query)
                         .select { |capture| capture.fetch("name").start_with?(DEFINITION) }
        end

        def start_of(capture, source, lines, language)
          documented_from(line_for(source, capture.fetch("start")), lines, language)
        end

        # The first line of the commentary run documenting the definition at
        # +line+, or +line+ itself. A run of blanks alone does not count, which
        # is why a marked line is looked for before the walk is kept.
        def documented_from(line, lines, language)
          run = (1...line).reverse_each.take_while { |above| commentary?(lines[above - 1], language) }.to_a
          run.any? { |above| marked?(lines[above - 1], language) } ? run.last : line
        end

        def commentary?(line, language) = blank?(line) || marked?(line, language)

        def blank?(line) = line.b.strip.empty?

        def marked?(line, language) = language.commentary.any? { |prefix| line.b.strip.start_with?(prefix) }

        # "method area", not "definition.method area": the kind is already
        # implied by everything in this list being a definition.
        def label_for(capture) = "#{capture.fetch("name").split(".").last} #{capture.fetch("text")}"

        # 1-based line from a byte offset, counting the same way
        # `Tools::FileSymbols#line_for` does.
        def line_for(source, start_byte) = source.byteslice(0, start_byte).b.count("\n") + 1

        def units(path:, lines:, first_line:, last_line:, label:)
          span = lines[(first_line - 1)..(last_line - 1)]
          return floor.pack(path:, lines: span, start_line: first_line, label:) if span.size > ceiling

          [Unit.new(path:, label:, start_line: first_line, lines: span)]
        end
      end
    end
  end
end
