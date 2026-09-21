# frozen_string_literal: true

module Lain
  module Frontend
    class Intake
      # What the history is spared: a line shaped like a credential is handed to
      # nobody, and every other line goes to the writer whole. The file is
      # append-only and outlives the session, so a key pasted at `you>` would
      # otherwise sit there for good.
      #
      # The WRITE tier, because what it judges is a human's own prose -- the
      # reason that tier exists ({CredentialPatterns}). The content tier's yaml
      # shape matches any `word: text`, which at a prompt is most lines.
      #
      # Judged as bytes: a terminal can hand over a line that is not valid in
      # its labelled encoding, and a raise here would unwind the read it answers.
      class Discretion
        # @param writer [#remember] the durable history -- {TTY#remember}
        # @param patterns [Hash{String => Regexp}] the shapes a line is withheld for
        def initialize(writer:, patterns: CredentialPatterns.for(:write))
          @writer = writer
          @patterns = patterns
        end

        def remember(line)
          bytes = line.b
          @writer.remember(line) unless @patterns.each_value.any? { |pattern| bytes.match?(pattern) }
        end
      end
    end
  end
end
