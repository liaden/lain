# frozen_string_literal: true

module Lain
  module Frontend
    class InputPane
      # The line typed at the pane while nothing is published. The terminal is
      # {Uncooked} then, so the kernel keeps no line and this does, which is
      # what lets the pane clear its input row and put the words back. The
      # editing a cooked terminal offered is kept -- erase, word erase, kill,
      # and a Tab as text -- and any other key that is not text is dropped. A
      # paste is text whole, its line ends included, and the approval key is
      # taken out wherever it falls.
      class Draft
        PASTE_OPEN = "\e[200~"
        PASTE_CLOSE = "\e[201~"
        ERASE = ["\x7f", "\b"].freeze
        WORD_ERASE = "\x17"
        KILL = "\x15"
        TEXT = /\A[^\x00-\x08\x0a-\x1f\x7f\e]/n

        # A key or a character a read cut short: the rest comes with the next read.
        UNFINISHED_KEY = /\e(?:\[[\d;?]*|O)?\z/n
        UNFINISHED_CHAR = /[\xC0-\xF7][\x80-\xBF]{0,2}\z/n

        # The approval key's bytes, and the pattern a read is cut into around them.
        Keys = Data.define(:cycle, :pattern) do
          # @param key [String] the bytes of the approval key
          # @return [Keys]
          def self.for(key)
            cycle = key.b.freeze
            new(cycle:, pattern: /#{Regexp.escape(cycle)}|#{StdinPump::Typeahead::KEY_SEQUENCE}|
                                  [\x00-\x08\x0a-\x1f\x7f]|[^\x00-\x08\x0a-\x1f\x7f\e]+/nx)
          end
        end

        # @param keys [Keys] the approval key and the read's pattern
        # @param seen [Boolean] whether the terminal was uncooked, so that what
        #   is typed is the pane's to echo and the draft is the input row
        def initialize(keys:, seen: false)
          @keys = keys
          @seen = seen
          @text = +""
          @held = "".b
          @paste = nil
          @cleared = false
        end

        def seen? = @seen

        # A line end inside the draft goes on as a paste, which no prompt takes for Enter.
        #
        # @return [String] what a read starting from this draft is handed
        def partial = (@text.include?("\n") ? "#{PASTE_OPEN}#{@text}#{PASTE_CLOSE}" : @text.dup).freeze

        # @return [String] the draft as the pane draws it on the input row
        def shown = @seen ? drawn(@text) : ""

        # @param columns [Integer] the terminal's width; 0 when it is unknown
        # @return [Integer] how many rows the drawn draft covers
        def rows(columns)
          widths = @text.split("\n", -1).map { |row| Reline::Unicode.calculate_width(drawn(row)) }
          [widths.sum { |width| columns.positive? ? [((width - 1) / columns) + 1, 1].max : 1 }, 1].max
        end

        # @param bytes [String] one read off the terminal
        # @yieldparam kind [Symbol] `:echo` with what to draw, `:line` with a
        #   finished line, or `:cycle` for the approval key
        # @yieldparam value [String, nil]
        def take(bytes, &)
          held_back(@held + bytes.b).scan(@keys.pattern) { |token| took(token, &) }
        end

        # A Ctrl-C: a cooked terminal flushed the line it held, and so does this.
        #
        # @yieldparam kind [Symbol] `:echo`, with what takes the draft off the row
        # @yieldparam value [String]
        def discard(&block) = erased(@text, &block)

        private

        def held_back(bytes)
          cut = [bytes =~ UNFINISHED_KEY, unfinished_char(bytes)].compact.min
          @held = cut ? bytes.byteslice(cut..) : "".b
          cut ? bytes.byteslice(0, cut) : bytes
        end

        def unfinished_char(bytes)
          at = bytes =~ UNFINISHED_CHAR
          at if at && bytes.bytesize - at < char_size(bytes.getbyte(at))
        end

        # A lead byte's leading 1 bits count the bytes of its character.
        def char_size(lead) = format("%08b", lead).index("0")

        def took(token, &block)
          return pasted(token, &block) if @paste

          case token
          when @keys.cycle then yield(:cycle, nil)
          when PASTE_OPEN then @paste = "".b
          when "\r", "\n" then ended(&block)
          when *ERASE then erased(@text[-1].to_s, &block)
          when WORD_ERASE then erased(@text[/\S*\s*\z/], &block)
          when KILL then erased(@text, &block)
          else added(Utf8.legible(token), &block) if token.match?(TEXT)
          end
        end

        def pasted(token, &block)
          return @paste << token unless token == PASTE_CLOSE

          body = Utf8.legible(@paste).gsub(/\r\n?/, "\n").chomp
          @paste = nil
          added(body, &block)
        end

        # A Tab is drawn as one column, so its width on the row is known.
        def drawn(text) = text.tr("\t", " ")

        # A withdrawn prompt leaves its words on the input row, so the first echo
        # clears it: from column 0 the rows the draft covers can be counted.
        def added(text)
          @text << text
          yield(:echo, "#{CLEAR_ROW unless @cleared}#{drawn(text)}") if @seen
          @cleared = true
        end

        def erased(gone, &block)
          return unwound(gone, &block) if gone.include?("\n")

          width = Reline::Unicode.calculate_width(drawn(gone))
          @text = @text[0, @text.length - gone.length]
          yield(:echo, ("\b" * width) + (" " * width) + ("\b" * width)) if @seen && width.positive?
        end

        # A backspace cannot climb a line end, so a draft losing one is drawn
        # again from its first row, as the header's redraw does.
        def unwound(gone)
          up = @text.count("\n")
          @text = @text[0, @text.length - gone.length]
          yield(:echo, "\e[#{up}A\r\e[J#{drawn(@text)}") if @seen
        end

        # A blank line says nothing: it is not sent, and it is gone, as a cooked read dropped it.
        def ended(&block)
          return erased(@text, &block) unless StdinPump::Typeahead::Typed.said?(@text)

          line = @text
          @text = +""
          yield(:echo, "\n") if @seen
          yield(:line, line)
        end
      end
    end
  end
end
