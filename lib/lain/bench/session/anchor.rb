# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Classifies and verifies a file's own anchor (T14): OPEN, CLOSED, or
      # this class's own always-anchored (offline recorder) shape. A separate
      # responsibility from {Loader}'s chain-following and turn-rebuilding --
      # this only ever looks at the header and the `session_closed` records,
      # never at a Timeline until {#verify} is actually asked to check one.
      #
      # An OPEN session is a live header (`head: nil`, {SessionRecord}'s
      # write-first shape) with no closer yet -- the SIGKILL case a reader
      # must recognize, not reject; it verifies only its own PREFIX, the
      # documented anti-truncation limit ({SessionRecord}'s class comment): a
      # write-first header cannot anchor a chain that does not exist yet.
      # Every other shape -- this class's own always-anchored header, or a
      # live session {#sole_session_closed} closed -- is checked against its
      # own recorded anchor: EITHER the header itself carries it (always
      # head-anchored, because it is written after the run) OR a
      # `session_closed` record does (the live scribe's header is written
      # open and never rewritten).
      #
      # A `run_interrupted` record never changes this classification: it
      # marks one ASK a stop beat, not the whole session, and its own `head`
      # is JOIN-OPTIONAL (a committed turn can outrun its turn record on a
      # kill between the Agent's commit and the journal write) -- tolerated
      # by never being consulted here at all.
      class Anchor
        # @param header [Hash] the sole session header record
        # @param session_closed_records [Array<Hash>] every `session_closed`
        #   record in the file (0 or 1; more raises {Corrupt})
        def initialize(header:, session_closed_records:)
          @header = header
          @closed = sole_closed(session_closed_records)
        end

        def open?
          @header["head"].nil? && @closed.nil?
        end

        # @return [Timeline] `chain`, unchanged
        # @raise [Corrupt] when `chain`'s rebuilt head disagrees with the
        #   recorded anchor
        def verify(chain)
          return chain if open?

          expected = anchor
          return chain if chain.head_digest == expected

          raise Corrupt, "the recorded anchor is #{expected.inspect} but the turn chain rebuilds to " \
                         "#{chain.head_digest.inspect}; the tail has been truncated or spliced"
        end

        private

        def anchor
          header_head = @header["head"]
          return header_head unless header_head.nil?

          @closed.fetch("head")
        end

        # Same discipline as {Loader#sole_header}: a session closes once, so a
        # second record would make "which close?" an accident of file order.
        # Nil (no record at all) means still open.
        def sole_closed(records)
          return records.first if records.size <= 1

          raise Corrupt, "#{records.size} \"session_closed\" records in one journal; " \
                         "a session closes once, one record pins the anchor"
        end
      end
    end
  end
end
