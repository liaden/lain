# frozen_string_literal: true

module Lain
  class Compare
    # The one fixed-width table renderer behind both {Compare#report} and
    # {Bench::Sweep#report} -- extracted because the two had grown byte-identical
    # private copies of the same layout. The rules are the report idiom, pinned
    # once: first column left-justified (labels), the rest right-justified
    # (numbers line up on the decimal), two spaces between columns, a dashed
    # rule under the header. Cells are Strings; formatting a value into a cell
    # stays the caller's job -- this object owns alignment, nothing else.
    class Table
      # @param headers [Array<String>]
      # @param rows [Array<Array<String>>] each row as wide as the headers
      def initialize(headers:, rows:)
        @headers = headers
        @rows = rows
        freeze
      end

      # @return [String] never printed here (output discipline)
      def to_s
        widths = column_widths
        separator = widths.map { |width| "-" * width }.join("  ")
        [line(@headers, widths), separator, *@rows.map { |row| line(row, widths) }].join("\n")
      end

      private

      def column_widths
        @headers.each_index.map { |i| ([@headers[i]] + @rows.map { |row| row[i] }).map(&:length).max }
      end

      def line(cells, widths)
        cells.each_index.map { |i| i.zero? ? cells[i].ljust(widths[i]) : cells[i].rjust(widths[i]) }.join("  ")
      end
    end
  end
end
