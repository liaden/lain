# frozen_string_literal: true

module Lain
  class Journal
    # Reads a session file's chain back: every line that carries a link must
    # carry the {Line.link} of the line before it. The file is streamed, so a
    # megabyte line is hashed once and only its tail is searched for its link.
    #
    # What it can and cannot see is the shape of the chain. A line is vouched
    # for by its SUCCESSOR, so an edit is named at the line after it, and the
    # last line has nobody: it is held only by a tip kept elsewhere. A crash is
    # not tampering: an unterminated last line is a torn tail, and a terminated
    # line that does not parse is the seal a chained reopen put on one, which
    # its successor's link covers.
    class Verify
      # @!attribute [r] lines
      #   @return [Integer] lines read, which stops at the first break
      # @!attribute [r] chained_from
      #   @return [Integer, nil] the first line carrying a link; the lines before it predate chaining
      # @!attribute [r] first_break
      #   @return [Integer, nil] the line to look at: whose link fails, or the last line for a
      #     tip mismatch or a torn tail
      # @!attribute [r] reason
      #   @return [Symbol] `:intact`, `:unchained`, `:edited`, `:tip_mismatch` or `:torn_tail`
      # @!attribute [r] tip
      #   @return [String, nil] the {Line.link} of the last line, nil once a break stopped the read
      # @!attribute [r] covered
      #   @return [Array<Integer>] unparseable lines, sealed crash tails, that a later link vouches for
      # @!attribute [r] unvouched
      #   @return [Array<Integer>] chained lines whose successor carries no link, so an edit of
      #     them reads intact: nothing downstream checks them
      # @!attribute [r] tip_line
      #   @return [Integer, nil] the line whose link the kept tip equalled (0 for the origin of
      #     an empty file); the lines after it are not checked by the tip
      Report = Data.define(:lines, :chained_from, :first_break, :reason, :tip, :covered, :unvouched, :tip_line)

      # Long enough for the longest link and the closing brace and newline.
      TAIL_BYTES = 128
      LINK_AT_END = /,"#{LINK}":"(#{Line::ORIGIN}|#{Canonical::DIGEST_ALGORITHM}:\h{64})"\}\n?\z/

      # @param path [String] a journal file that exists
      def initialize(path)
        @path = path
      end

      # @param tip [String, nil] a tip recorded when the file was last seen; the last line is
      #   checked against it, and a file that has grown since still holds it as the link of
      #   one of its lines
      # @return [Report]
      def call(tip: nil)
        walk = Walk.new(tip)
        File.foreach(@path, mode: "rb").with_index(1).find { |line, number| walk.broken?(line, number) }
        walk.report
      end

      # The state of one pass, so the verdict is a function of the lines alone.
      class Walk
        def initialize(kept)
          @kept = kept
          @lines = 0
          @expected = Line::ORIGIN
          @covered = []
          @unvouched = []
          @terminated = true
        end

        # @return [Boolean] whether this line's link names something other than the line before it
        def broken?(line, number)
          @lines = number
          @terminated = line.end_with?("\n")
          link = linked(line)
          @chained_from ||= number if link
          @break = number if link && link != @expected
          settle(line, link, number) if @break.nil?
          !@break.nil?
        end

        # @return [Report]
        def report
          Report.new(lines: @lines, chained_from: @chained_from, first_break:, reason:,
                     tip: @break ? nil : @expected, covered: @covered, unvouched:, tip_line:)
        end

        private

        def linked(line)
          start = [line.bytesize - TAIL_BYTES, 0].max
          LINK_AT_END.match(line.byteslice(start, TAIL_BYTES))&.then { |found| found[1] }
        end

        # A line without its own link is judged only if the next one vouches for it, so the
        # parse is spent on the rare line that has none.
        def settle(line, link, number)
          @covered << (number - 1) if link && @previous && Line.classify(@previous, last: false) == :damage
          @previous = link ? nil : line
          track_unvouched(link, number)
          @expected = Line.link(line)
          @kept_at ||= number if @expected == @kept
        end

        # The first unlinked line of a run names the chained line before it, which nothing
        # downstream checks; the run counts once a link, or a complete last line, ends it.
        def track_unvouched(link, number)
          @pending ||= number - 1 if !link && @chained_from
          return unless link && @pending

          @unvouched << @pending
          @pending = nil
        end

        # A torn tail is left out: the torn verdict already says its predecessor is unchecked.
        def unvouched = @pending && @terminated ? [*@unvouched, @pending] : @unvouched

        def tip_line = @kept_at || (@kept == @expected ? @lines : nil)

        def reason
          return :edited if @break
          return :tip_mismatch unless tip_held?
          return :unchained unless @chained_from

          @terminated ? :intact : :torn_tail
        end

        def tip_held? = @kept.nil? || !tip_line.nil?

        def first_break = @break || (%i[tip_mismatch torn_tail].include?(reason) ? @lines : nil)
      end
    end
  end
end
