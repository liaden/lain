# frozen_string_literal: true

module Lain
  class Journal
    # Bytes in, parsed lines out, for a reader that sees a file in chunks cut anywhere. The torn
    # fragment is kept as binary, because a chunk may end inside a multibyte character and a
    # binary chunk appended to a UTF-8 fragment raises.
    #
    # It answers Hashes, never typed records: reading them is the caller's own step, strict for
    # a resume and lenient for `lain watch`, so the Tail itself never raises on foreign or torn bytes.
    class Tail
      NEWLINE = "\n"

      def initialize
        @fragment = String.new(encoding: Encoding::BINARY)
      end

      # Splits only when a newline arrived, so a long line landing in small chunks is not rescanned per chunk.
      #
      # @param chunk [String] any bytes, in any encoding
      # @return [Array<Hash{String=>Object}>] the records of the lines this chunk completed
      def <<(chunk)
        bytes = chunk.b
        @fragment << bytes
        bytes.include?(NEWLINE) ? completed : []
      end

      private

      def completed
        lines = @fragment.lines
        @fragment = lines.last.end_with?(NEWLINE) ? String.new(encoding: Encoding::BINARY) : lines.pop
        lines.filter_map { |line| Journal.parse(line) }
      end
    end
  end
end
