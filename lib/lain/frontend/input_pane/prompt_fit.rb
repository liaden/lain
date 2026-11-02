# frozen_string_literal: true

module Lain
  module Frontend
    class InputPane
      # Fits an approval prompt to the rows the pane has: the call and the
      # reasons keep both ends and lose the middle, so the tail, which holds the
      # `[y/N]` and the deadline, is always the last row. The pane draws the
      # rows above the tail itself, because the line editor takes one line.
      class PromptFit
        # The row standing where rows were cut.
        CUT = "[...]"
        NOTE = "%<bytes>d bytes of the call are hidden; the full call is in lain://approval"

        # @param frame [Hash] the chat's prompt frame
        # @param geometry [#window] the pane's window, `[rows, columns]` or nil
        # @param header_rows [Integer] the rows the header takes above the prompt
        # @return [Array<String>] the rows to draw, the last one the editor's own prompt
        def self.rows(frame, geometry, header_rows:)
          parts = frame["parts"].to_h
          window = parts.empty? ? nil : geometry.window
          return [frame["text"].to_s] unless window

          new(rows: window.first - header_rows, columns: window.last).call(parts, frame["text"].to_s)
        end

        # @param rows [Integer] the rows the prompt may take, editor row included
        # @param columns [Integer] the width a row wraps at
        def initialize(rows:, columns:)
          @rows = rows - 1
          @columns = [columns, 1].max
        end

        # @param parts [Hash] `lead`, `call`, `reasons` and `tail`
        # @param whole [String] the prompt as one line, drawn as is when it fits
        # @return [Array<String>]
        def call(parts, whole)
          return [whole] if wrapped(whole).size <= @rows

          limit = [@rows, 1].max
          note_rows = limit >= 3 ? 1 : 0
          *shown, hidden = fitted(parts, limit - 1 - note_rows)
          [*shown.flatten(1), *note(hidden, note_rows), parts["tail"].to_s]
        end

        private

        def fitted(parts, room)
          lead, call, reasons = [parts["lead"], parts["call"], Array(parts["reasons"]).join("\n")].map { wrapped(_1) }
          lead_room = [lead.size, [room / 4, 1].max, room].min
          reasons_room = [reasons.size, (room - lead_room) / 4].min
          cuts = [[lead, lead_room], [call, room - lead_room - reasons_room], [reasons, reasons_room]].map { cut(*_1) }
          [*cuts.map(&:first), cuts.sum(&:last)]
        end

        def note(hidden, rows) = hidden.zero? || rows.zero? ? [] : [format(NOTE, bytes: hidden)]

        def wrapped(text)
          text.to_s.split("\n").flat_map { |line| line.empty? ? [line] : line.scan(/.{1,#{@columns}}/m) }
        end

        def cut(rows, room)
          return [rows, 0] if rows.size <= room
          return [[], rows.join.bytesize] unless room.positive?

          head = room / 2
          tail = [room - 1 - head, 0].max
          [[*rows.first(head), CUT, *rows.last(tail)], rows[head...(rows.size - tail)].join.bytesize]
        end
      end
    end
  end
end
