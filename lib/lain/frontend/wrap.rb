# frozen_string_literal: true

module Lain
  module Frontend
    # Breaks transcript text at word boundaries for a terminal `width` columns
    # wide. Only the terminal can reflow, and it breaks at the column edge, mid
    # word; this runs when a line is written, so a later resize is not followed.
    #
    # Widths come from {Lain::Ext::Prompt.width}, which is grapheme-aware and
    # ignores styling escapes. A line's leading indentation is repeated on its
    # continuations, and a line that already fits is returned byte for byte.
    # Lines inside a fenced code block pass through, so copied code never
    # gains a newline.
    module Wrap
      ESCAPE_SOURCE = '\e\[[0-9;?]*[A-Za-z]'
      # An escape sequence, or a run of anything else that is not a space: a
      # word may carry a colour change in its middle.
      WORD = /(?:#{ESCAPE_SOURCE}|[^ \e])+|\e/
      GAPPED = /( *)(#{WORD})/
      ESCAPE = /\A#{ESCAPE_SOURCE}\z/
      LEAD = /\A((?:#{ESCAPE_SOURCE})*)([ \t]*)/
      FENCE = /\A(?:#{ESCAPE_SOURCE})*\s*```/
      TAB_STOP = 8

      # A file name is bytes and may not be UTF-8; it cannot be measured, and
      # a note naming one must still print, so it passes through whole.
      #
      # @param text [String] may hold newlines and styling escapes
      # @param width [Integer] columns; zero or less leaves the text alone
      # @param eol [String] what joins the rows: a terminal in raw mode needs
      #   "\r\n", since a bare newline there only moves down
      # @return [String] escapes kept and not counted
      def self.call(text, width:, eol: "\n")
        return text unless width.positive? && text.valid_encoding?

        fenced = false
        text.split("\n", -1).flat_map do |line|
          fenced = !fenced if line.match?(FENCE)
          fenced || line.match?(FENCE) ? [line] : Line.new(line, width).to_a
        end.join(eol)
      end

      # One source line, laid out greedily into rows.
      class Line
        def initialize(line, width)
          @source = line
          @width = width
          @line = expand_tabs(line)
          _, @lead, @indent = @line.match(LEAD).to_a
          @words = @line.delete_prefix(@lead + @indent).scan(GAPPED)
          @indent = "" unless Lain::Ext::Prompt.width(@indent) < width
          @room = width - Lain::Ext::Prompt.width(@indent)
          @rows = []
          @row = +""
          @used = 0
        end

        # @return [Array<String>] the rows, never empty
        def to_a
          return [@source] if Lain::Ext::Prompt.width(@line) <= @width

          @words.each { |gap, word| place(gap.size, word) }
          flush
          @rows.first.prepend(@lead)
          @rows
        end

        private

        def expand_tabs(line)
          return line unless line.include?("\t")

          column = 0
          line.gsub(/\t|#{ESCAPE_SOURCE}|[^\t\e]+/o) do |piece|
            text = piece == "\t" ? " " * (TAB_STOP - (column % TAB_STOP)) : piece
            column += Lain::Ext::Prompt.width(text)
            text
          end
        end

        def place(gap, word)
          size = Lain::Ext::Prompt.width(word)
          return hard_break(word) if size > @room

          flush if @used.positive? && @used + gap + size > @room
          append(gap, word, size)
        end

        def append(gap, word, size)
          gap = 0 if @used.zero?
          @row << (" " * gap) << word
          @used += gap + size
        end

        def flush
          @rows << (@indent + @row)
          @row = +""
          @used = 0
        end

        def hard_break(word)
          flush if @used.positive?
          pieces(word).each do |piece, size|
            flush if @used.positive? && @used + size > @room
            @row << piece
            @used += size
          end
        end

        def pieces(word)
          word.scan(/#{ESCAPE_SOURCE}|\X/o).map do |piece|
            [piece, piece.match?(ESCAPE) ? 0 : Lain::Ext::Prompt.width(piece)]
          end
        end
      end
      private_constant :Line
    end
  end
end
