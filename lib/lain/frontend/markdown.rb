# frozen_string_literal: true

module Lain
  module Frontend
    # A model reply's markdown as {Lain::Renderable} segments. Five constructs
    # and nothing more: `**bold**`, `inline code`, fenced blocks, `#` headings
    # and `-`/`*` bullets. A gem would render HTML or drag in a highlighter;
    # this reads a line at a time.
    module Markdown
      INLINE = /`([^`\n]+)`|\*\*(.+?)\*\*/
      HEADING = /\A#+ +(.*)\z/
      BULLET = /\A( *)[-*] +(.*)\z/
      FENCE = /\A\s*```/
      GLYPH = "•"
      NEWLINE = "\n"

      # @param text [String]
      # @param prose [Symbol] the token for words with no markup, so a reply
      #   keeps its colour while a command can leave them plain
      # @return [Lain::Renderable] the words without their markers, each run
      #   under its construct's token; fence lines are dropped
      def self.segments(text, prose: Renderable::PLAIN)
        lines = body_lines(text, prose)
        lines.each_with_index.inject(Renderable.new) do |all, (line, index)|
          (index.zero? ? all : all.plain(NEWLINE)) + line
        end
      end

      # Rows (0-based, counting newlines in the rendered text) that are whole
      # lines of a code block. The fences that told {Wrap} to leave them alone
      # are gone, so the rows are named instead.
      #
      # @param renderable [Lain::Renderable] from {.segments}
      # @return [Array<Integer>]
      def self.verbatim_rows(renderable)
        rows = renderable.text.split(NEWLINE, -1).map { [] }
        row = 0
        renderable.each do |segment|
          rows[row] << segment.token unless segment.text == NEWLINE
          row += 1 if segment.text == NEWLINE
        end
        rows.each_index.select { |index| rows[index].any? && rows[index].all?(:code) }
      end

      def self.body_lines(text, prose)
        fenced = false
        marked = text.to_s.split(NEWLINE, -1).map { |line| safe(line) }
                     .map { |line| [line, line.match?(FENCE), fenced ^= line.match?(FENCE)] }
        marked.reject { |_, fence, _| fence }
              .map { |line, _, inside| inside ? Renderable.new.with(:code, line) : line_segments(line, prose) }
      end
      private_class_method :body_lines

      # Newline and tab are layout; any other control byte would reach the terminal as a command from the model.
      def self.safe(line) = Utf8.escaped(line.chomp("\r"), keep: "\n\t")
      private_class_method :safe

      def self.line_segments(line, prose)
        case line
        when HEADING then Renderable.new.with(:heading_md, Regexp.last_match(1))
        when BULLET then bullet(Regexp.last_match(1), Regexp.last_match(2), prose)
        else inline(line, prose)
        end
      end
      private_class_method :line_segments

      def self.bullet(indent, words, prose)
        lead = indent.empty? ? Renderable.new : Renderable.new.with(prose, indent)
        lead.with(:bullet, GLYPH) + inline(" #{words}", prose)
      end
      private_class_method :bullet

      def self.inline(line, prose)
        rest = line
        found = Renderable.new
        while (match = INLINE.match(rest))
          found += plain_run(match.pre_match, prose)
          found = found.with(match[1] ? :code : :emphasis, match[1] || match[2])
          rest = match.post_match
        end
        found + plain_run(rest, prose)
      end
      private_class_method :inline

      def self.plain_run(text, prose) = text.empty? ? Renderable.new : Renderable.new.with(prose, text)
      private_class_method :plain_run
    end
  end
end
