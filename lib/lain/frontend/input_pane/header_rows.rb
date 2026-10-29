# frozen_string_literal: true

module Lain
  module Frontend
    class InputPane
      # What the pane writes on the rows above its prompt, and the row
      # arithmetic that decides how: the escape sequences that rewrite a header
      # in place or print it over the row the cursor is on, and the one-time
      # hint under it. The pane decides WHEN; this is the only writer of the
      # bytes.
      class HeaderRows
        # @return [Boolean] whether two headers have the same, nonzero, row count,
        #   so one can be rewritten over the other without moving the input row
        def self.same_count?(shown, wanted)
          rows = wanted.split("\n")
          !rows.empty? && rows.size == shown.split("\n").size
        end

        # @param tty [#print_prompt] the pane's terminal
        def initialize(tty:)
          @tty = tty
          @hinted = nil
        end

        # @param header [String] the rows to put where the old ones were
        def rewrite(header)
          rows = header.split("\n")
          @tty.print_prompt("\e7\e[#{rows.size}A#{rows.map { |row| "#{CLEAR_ROW}#{row}\n" }.join}\e8")
        end

        # The cursor is wherever the read this frame replaced left it -- mid-row,
        # after a `you> ` the editor had already drawn -- so the row is taken back
        # before the header goes on it. Without this a redraw printed
        # `you> ❄ fleet:4 inbox:0` as one line and cost the pane a row of its six.
        def over(header)
          return if header.to_s.empty?

          @tty.print_prompt("#{CLEAR_ROW}#{header}\n")
        end

        # @param frame [Hash] the chat's prompt frame; only a `you` prompt not yet hinted is
        def hint(frame)
          return unless frame["kind"] == "you" && frame["generation"] != @hinted

          @hinted = frame["generation"]
          @tty.print_prompt("#{CLEAR_ROW}#{MULTILINE_HINT}\n")
        end
      end
    end
  end
end
