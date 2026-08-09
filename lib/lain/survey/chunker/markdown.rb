# frozen_string_literal: true

module Lain
  module Survey
    module Chunker
      Markdown = Data.define(:ceiling, :floor, :granularity)

      # Markdown chunked by its OWN section tree, read from tree-sitter's
      # markdown grammar rather than from a `^#+` regex.
      #
      # The grammar earns its place three times over: `section` nodes nest by
      # heading level, so the tree IS the hierarchy a label needs; a `#`-looking
      # line inside a fenced code block is `code_fence_content` and opens
      # nothing; and a heading's own text arrives as a node rather than as a
      # capture group somebody has to strip.
      #
      # == Adaptive depth, and why fixed depth is useless
      #
      # A section that fits under the ceiling is ONE unit, whole. One that does
      # not becomes its own prose plus a unit per child, recursively. A leaf
      # still over the ceiling falls to the paragraph floor. Fixed depth cannot
      # work on real documents -- this repository's own CLAUDE.md has H2
      # sections in the hundreds of lines and H3s of four.
      #
      # == The heading is INSIDE the hashed body
      #
      # Inverting {Review::Hunk}'s rule deliberately. A hunk excludes its `@@`
      # line because that line is derived POSITION; a markdown heading is
      # authored CONTENT, so rewording it should cost the section its mark and
      # force a re-read.
      #
      # == Setext headings, including the MIXED document
      #
      # Measured, not assumed: a `setext_heading` node exists but opens no
      # section, so a document of two setext headings parses as ONE section
      # holding both, and takes the paragraph floor. Teaching this chunker a
      # second boundary rule is exactly the regex the grammar was chosen to
      # avoid.
      #
      # A MIXED document -- ATX headings with setext ones under them, which is
      # an ordinary README -- is the case worth stating: the setext headings
      # open no section, so their text is absorbed into the enclosing ATX
      # section. EXTENT stays faithful (every line is still covered exactly
      # once, and an oversized absorbing section still descends or falls to the
      # floor); what is lost is only the LABEL, which names the ATX ancestry
      # and never the setext heading a reader can see in the body.
      class Markdown
        LANGUAGE = "markdown"

        def initialize(ceiling: DEFAULT_CEILING, floor: Paragraphs.new(ceiling:),
                       granularity: Granularity.new)
          super(ceiling: Integer(ceiling), floor:, granularity:)
        end

        # @param path [String] the path the units will carry
        # @param source [String] the whole file
        # @return [Array<Unit>] ordered, covering every line exactly once
        def call(path:, source:)
          # The ext refuses a source it would have to transcode, and its refusal
          # names a byte offset in a file this layer cannot name back. A survey
          # that cannot read a stray latin-1 file at all is worse than one that
          # reads it as prose, so the floor takes it -- the same answer this
          # chunker already gives an oversized leaf.
          return floor.call(path:, source:) unless Chunker.parseable?(source)

          lines = Unit.lines_of(source)
          granularity.coalesce(
            cover(path:, lines:, sections: tree(source, lines.size), from: 1, to: lines.size, label: "")
          )
        end

        private

        # One section and the sections nested inside it. Mutable, and only
        # while {#tree} builds it -- the frozen value this produces is the
        # {Unit}, not this.
        class Section
          attr_reader :first_line, :last_line, :label, :children

          def initialize(first_line:, last_line:, label:)
            @first_line = first_line
            @last_line = last_line
            @label = label
            @children = []
          end

          def line_count = last_line - first_line + 1

          def adopt(child)
            children << child
            child
          end
        end
        private_constant :Section

        # The captures arrive FLAT and overlapping -- an H2's range sits inside
        # its H1's -- so containment is the hierarchy, and a stack over spans
        # ordered outermost-first rebuilds it. The document itself is the
        # stack's floor, and `size > 1` is what makes that promise total: a
        # section the grammar reports beyond the last line would otherwise pop
        # the sentinel and leave the next reader with a nil.
        def tree(source, line_count)
          captures = Ext::TreeSitter.query(source, LANGUAGE, Structural::Queries.fetch(:markdown, :sections))
          document = Section.new(first_line: 1, last_line: line_count, label: "")
          nest(spans(captures, source), [document])
          document.children
        end

        # Every byte offset is turned into a line here, so nothing downstream
        # holds two coordinate systems at once.
        def spans(captures, source)
          headings = headings_by_start(captures)
          outermost_first(captures).map do |start, finish|
            [line_for(source, start), line_for(source, [finish - 1, start].max), headings[start]]
          end
        end

        # A heading belongs to the section starting at the same byte -- the
        # correlation the flat capture list cannot make for us.
        def headings_by_start(captures)
          named(captures, "heading").to_h { |capture| [capture.fetch("start"), heading_text(capture.fetch("text"))] }
        end

        def outermost_first(captures)
          named(captures, "section").map { |capture| [capture.fetch("start"), capture.fetch("end")] }
                                    .uniq.sort_by { |start, finish| [start, -finish] }
        end

        def named(captures, name) = captures.select { |capture| capture.fetch("name") == name }

        def nest(spans, stack)
          spans.each do |(first_line, last_line, heading)|
            stack.pop while stack.size > 1 && stack.last.last_line < first_line
            parent = stack.last
            stack.push(parent.adopt(Section.new(first_line:, last_line:, label: compose(parent.label, heading))))
          end
        end

        # A section with no ATX heading of its own -- the setext case -- keeps
        # its parent's label rather than inventing one from its first line.
        def compose(parent, heading)
          return parent if heading.nil?

          parent.empty? ? heading : "#{parent} > #{heading}"
        end

        def heading_text(text) = text.delete_suffix("\n").sub(/\A\#+[ \t]*/, "").sub(/[ \t]*\#+\z/, "").strip

        # 1-based line from a byte offset, counting the same way
        # `Tools::FileSymbols#line_for` does: `.b` keeps a boundary landing mid
        # multi-byte character from raising, since a newline is one ASCII byte
        # whatever the encoding tag says.
        def line_for(source, start_byte) = source.byteslice(0, start_byte).b.count("\n") + 1

        # Units covering [from, to] EXACTLY: each section's own units, and the
        # floor over every line no section claims. Frontmatter, a preamble
        # before the first heading, and a parent's own prose above its first
        # child are all the same case, which is why none of them is special.
        def cover(path:, lines:, sections:, from:, to:, label:)
          cursor, units = sections.inject([from, []]) do |(line, acc), section|
            [section.last_line + 1,
             acc + gap(path:, lines:, from: line, to: section.first_line - 1, label:) +
               units_for(section, path:, lines:)]
          end
          units + gap(path:, lines:, from: cursor, to:, label:)
        end

        def gap(path:, lines:, from:, to:, label:)
          return [] if to < from

          floor.pack(path:, lines: lines[(from - 1)..(to - 1)], start_line: from, label:)
        end

        def units_for(section, path:, lines:)
          return [whole(section, path:, lines:)] if section.line_count <= ceiling
          return packed(section, path:, lines:) if section.children.empty?

          cover(path:, lines:, sections: section.children, label: section.label,
                from: section.first_line, to: section.last_line)
        end

        def whole(section, path:, lines:)
          Unit.new(path:, label: section.label, start_line: section.first_line, lines: span(section, lines))
        end

        def packed(section, path:, lines:)
          floor.pack(path:, lines: span(section, lines), start_line: section.first_line, label: section.label)
        end

        def span(section, lines) = lines[(section.first_line - 1)..(section.last_line - 1)]
      end
    end
  end
end
