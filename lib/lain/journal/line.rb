# frozen_string_literal: true

module Lain
  class Journal
    # What a line {Journal.parse} refused is, for the readers that must not skip
    # silently: one rule, so a torn tail means the same thing in every one of
    # them. Each reader keeps its own response to the answer.
    module Line
      # An unterminated last line is judged before blank and foreign because a
      # crash between the bytes and the newline can leave any of them, and the
      # reader's tolerance for that is the same.
      #
      # @param line [Hash, String] one entry of the {Journal.records} duck
      # @param last [Boolean] whether it is the final line of the file
      # @return [Symbol] `:record`, `:tail` (last and unterminated), `:blank`,
      #   `:foreign` (JSON, but not a Hash record), or `:damage`
      def self.classify(line, last:)
        return :record if Journal.parse(line)
        return :foreign unless line.is_a?(String)
        return :tail if last && !line.end_with?("\n")
        return :blank if line.strip.empty?

        JSON.parse(line)
        :foreign
      rescue JSON::ParserError
        :damage
      end
    end
  end
end
