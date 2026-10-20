# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Classifies and verifies a file's own anchor: OPEN or CLOSED. It looks
      # only at the `session_closed` records, never at a Timeline until
      # {#verify} is asked to check one.
      #
      # An OPEN session has no closer yet -- the SIGKILL case a reader must
      # recognize rather than reject. It verifies only its own PREFIX, the
      # documented anti-truncation limit, because a write-first header cannot
      # anchor a chain that does not exist yet. A CLOSED session is checked
      # against the head its `session_closed` record carries.
      #
      # A `run_interrupted` record never changes this classification: it marks
      # one ASK a stop beat, not the whole session, and its own `head` is
      # JOIN-OPTIONAL, since a committed turn can outrun its turn record on a
      # kill between the Agent's commit and the journal write. Tolerated by
      # never being consulted here at all.
      class Anchor
        # @param session_closed_records [Array<Hash>] every `session_closed`
        #   record in the file (0 or 1; more raises {Corrupt})
        def initialize(session_closed_records:)
          @closed = sole_closed(session_closed_records)
        end

        def open? = @closed.nil?

        # @return [Ext::Timeline] `chain`, unchanged
        # @raise [Corrupt] when `chain`'s rebuilt head disagrees with the
        #   recorded anchor
        def verify(chain)
          return chain if open?

          expected = @closed.fetch("head")
          return chain if chain.head_digest == expected

          raise Corrupt, "the recorded anchor is #{expected.inspect} but the turn chain rebuilds to " \
                         "#{chain.head_digest.inspect}; the tail has been truncated or spliced"
        end

        private

        # A session closes once, so a second record would make "which close?"
        # an accident of file order. No record at all means still open.
        def sole_closed(records)
          return records.first if records.size <= 1

          raise Corrupt, "#{records.size} \"session_closed\" records in one journal; " \
                         "a session closes once, one record pins the anchor"
        end
      end
    end
  end
end
