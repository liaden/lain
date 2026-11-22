# frozen_string_literal: true

module Lain
  module Frontend
    class InputPane
      # Says a note in the scrollback of a pane that has a header and a draft row drawn below its last output: both
      # are taken back first and drawn again beneath the note, so it never lands on the row the human is typing in.
      # The same redraw serves a header that changed under a draft.
      class NoteLine
        # The terminal call that says each kind of note.
        SAYS = { "held" => :render_held, "human" => :render_human_note }.freeze

        # @param tty [#print_prompt, #render_note] the pane's terminal
        # @param view [#call] what is on screen as `[header, draft, columns]`, or nil when no header and draft are
        #   drawn to take back; `draft` answers `shown` and `rows(columns)`
        def initialize(tty:, view:)
          @tty = tty
          @view = view
        end

        # @param text [String]
        # @param kind [String, nil] `held` or `human`; anything else is said as a plain note
        # @return [void]
        def say(text, kind = nil)
          shown, draft, columns = @view.call
          return @tty.public_send(SAYS.fetch(kind, :render_note), text) if shown.nil?

          @tty.print_prompt(taken_back(shown, draft, columns))
          @tty.public_send(SAYS.fetch(kind, :render_note), text)
          @tty.print_prompt(drawn(shown, draft))
        end

        # @param wanted [String] the header rows to draw in place of the ones on screen
        # @return [Integer] how many rows the new header covers
        def redraw(wanted)
          shown, draft, columns = @view.call
          @tty.print_prompt("#{taken_back(shown, draft, columns)}#{drawn(wanted, draft)}")
          wanted.split("\n").size
        end

        private

        def taken_back(shown, draft, columns) = "\e[#{shown.split("\n").size + draft.rows(columns) - 1}A\r\e[J"

        def drawn(header, draft) = "#{CLEAR_ROW}#{header}\n#{draft.shown}"
      end
    end
  end
end
