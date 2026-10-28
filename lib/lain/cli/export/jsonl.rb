# frozen_string_literal: true

module Lain
  module CLI
    class Export
      # The session file's own lines, untouched, so the export is the record
      # stream and not a re-encoding of it.
      class Jsonl
        def initialize(lines:)
          @lines = lines
        end

        # @return [String] one line per record, newline terminated
        def render = @lines.map { |line| "#{line}\n" }.join
      end
    end
  end
end
