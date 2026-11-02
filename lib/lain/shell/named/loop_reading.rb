# frozen_string_literal: true

require "strscan"

module Lain
  module Shell
    class Named
      # A `for` loop over plain words, read as its body once per word, so each
      # pass names the paths its stages name.
      #
      # The loop is read off the source text, so the grammar has to agree with
      # that reading: it parsed clean, and the only bytes it left unread are the
      # loop's own `for`, name, `in`, `do` and `done`. A body holding a `do`,
      # `done` or `for` of its own could end the loop where bash would not, so
      # it is not read. A word is a bare run that bash neither splits, globs nor
      # expands, so the body sees exactly its text. The name is lowercase,
      # because bash's own variables, PATH and IFS among them, are not.
      #
      # @api private
      class LoopReading
        NAME = /[a-z][a-z0-9_]*/
        WORD = %r{[A-Za-z0-9._/+,:@%=-]+}
        LOOP = /
          \A\s*for[ \t]+(?<name>#{NAME})[ \t]+in(?<words>(?:[ \t]+#{WORD})+)[ \t]*[;\n]
          \s*do\s(?<body>.*)[;\n]\s*done\s*\z
        /mx
        KEYWORDS = %w[for do done].freeze
        TOKEN_GAP = /[\s;&|()<>]+/
        FOR = "for_statement"
        # Copied as written: bash expands no `$` inside single quotes or after a backslash.
        LITERAL = /'[^']*'|\\./m
        COMMENT = "#"
        SINGLE = "'"
        DOUBLE = '"'

        # @param result [Parse::Result]
        # @return [Parse::Result, nil] the body's passes, one per line, parsed;
        #   nil for anything but a whole loop this object can read
        def self.unrolled(result)
          return unless result.kinds.include?(FOR) && result.breakages.empty?

          found = LOOP.match(result.source)
          new(found).unrolled if found && agrees?(result, found)
        end

        def self.agrees?(result, found)
          unread = result.uncovered.map { result.source.byteslice(_1) }
          unread == ["for", found[:name], "in", "do", "done"] && !found[:body].split(TOKEN_GAP).intersect?(KEYWORDS) &&
            quotes_read?(found[:body])
        end

        # {LITERAL} cannot tell a `'` inside double quotes or a comment from
        # one that opens a single-quoted span, so a body where that could
        # matter is not read.
        def self.quotes_read?(body) = !body.include?(COMMENT) && !(body.include?(SINGLE) && body.include?(DOUBLE))
        private_class_method :agrees?, :quotes_read?

        # @param found [MatchData] of {LOOP}
        def initialize(found)
          @words = found[:words].split
          @body = found[:body]
          @reference = /\$(?:#{found[:name]}(?![A-Za-z0-9_])|\{#{found[:name]}\})/
        end

        # A newline between passes, not a `;`, so a comment ending one pass
        # cannot swallow the next.
        #
        # @return [Parse::Result]
        def unrolled = Parse.new.call(@words.map { pass(_1) }.join("\n"))

        private

        def pass(word)
          scanner = StringScanner.new(@body)
          text = +""
          text << (scanner.scan(LITERAL) || (scanner.scan(@reference) && word) || scanner.getch) until scanner.eos?
          text
        end
      end
    end
  end
end
