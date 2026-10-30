# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # lain://todos: the session's current todo list, one line per item.
      # {StatusView}'s shape (`initial` / `update(event)`, plain lines, never nvim).
      #
      # The list is read off the {Session} on every event and surfaced only when
      # the drawn lines moved, as the workspace view is: a tool's stdout arrives
      # many times a second and must not rewrite a buffer nothing changed in.
      class TodoView
        NAME = "lain://todos"

        EMPTY = ["(no todos)"].freeze

        # Open work first; the glyph is the item's status.
        GLYPHS = { "pending" => "[ ]", "in_progress" => "[~]", "completed" => "[x]" }.freeze

        # @param session [#todos]
        def initialize(session:)
          @session = session
          @shown = nil
        end

        # @return [Array<String>]
        def initial = @shown = lines

        # @param _event [Object] one Channel event; the session is the source
        # @return [Array<String>, nil] the whole buffer, or nil when it did not move
        def update(_event)
          drawn = lines
          return nil if drawn == @shown

          @shown = drawn
        end

        private

        def lines
          items = @session.todos.sort_by.with_index { |todo, index| [rank(todo), index] }
          items.empty? ? EMPTY : items.map { |todo| row(todo) }
        end

        def rank(todo) = GLYPHS.keys.index(todo["status"]) || GLYPHS.size

        def row(todo)
          content = Utf8.legible(todo["content"], "?").gsub(Text::NEWLINES, " ")
          "#{GLYPHS.fetch(todo["status"], "[?]")} #{content}"
        end
      end
    end
  end
end
