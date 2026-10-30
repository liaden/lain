# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # What an `edit_file` call changed: each removed line behind a `-`, each
      # added line behind a `+`, and a count of what the tool cut off.
      class EditDiff
        LIMIT = 20

        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = false

        # @param theme [Frontend::Theme]
        # @return [String] the diff lines joined by newlines, no trailing one
        def render(theme) = segments(theme).join("\n")

        # @param theme [Frontend::Theme]
        # @return [Array<String>] one painted entry per line, then the footer when lines were cut
        def segments(theme)
          [*painted(theme, :removed, "-", @event.removed), *painted(theme, :added, "+", @event.added), *footer]
        end

        private

        def painted(theme, token, sign, lines) = lines.map { |line| theme.paint(token, "#{sign}#{Utf8.escaped(line)}") }

        def footer = (["… #{@event.hidden} more lines"] if @event.hidden.positive?)
      end
    end
  end
end
