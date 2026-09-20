# frozen_string_literal: true

module Lain
  module Epic
    # A human took a document, journaled by {Review#open} BEFORE the baton is
    # held. An INTENT and not an ack, the opposite of {DocWritten} and for the
    # opposite reason: a crash between the record and the live baton leaves a
    # claim that rebuilds as OPEN with nothing behind it, which refuses a write
    # the record would also have refused. Journaling second would lose the claim,
    # and a lost claim reads as "nobody is holding this".
    #
    # `path` is ABSOLUTE, the one place this unit departs from {DocWritten}'s
    # relative path and a deliberate departure: a review is a LIVE question about
    # a file on this machine -- the exact string {Home::Journaled}'s reviews duck
    # is asked about ({Home::Artifact#path}) -- and {Review.from_journal} rebuilds
    # the open set from nothing but these records, so a relative path would
    # rebuild a baton no `open?` can match. The durable, portable join is
    # `epic_slug` plus the two digests, which travel between machines as
    # `doc_written`'s do.
    #
    # `generation` is unique within `epic_slug` and NOT within the journal: two
    # epics sharing one journal both hand out 1, because each numbers from its
    # own records and there is deliberately no counter between them ({Review}
    # says why). So the identity is the PAIR, and a `generation` read off one of
    # these lines means nothing without the `epic_slug` on the same line. Given
    # both, the stale-buffer guarantee holds -- a buffer left over from a dead
    # process names a generation that is settled or unknown within its own epic,
    # never one that now belongs to another review.
    ReviewOpened = Data.define(:epic_slug, :path, :generation, :written_digest, :graph_digest) do
      include Telemetry::Journalable

      # `&&=` as {DocWritten} does, and for its reason: three of the four stages
      # are prose, which has no graph to address. A bare `-graph_digest.to_s`
      # would turn that nil into `""` -- an address-shaped string addressing
      # nothing.
      def initialize(epic_slug:, path:, generation:, written_digest:, graph_digest: nil)
        claim = ReviewClaim.interned(epic_slug:, path:, generation:, written_digest:)
        graph_digest &&= -graph_digest.to_s
        Contracts::ReviewOpened.check!(**claim, graph_digest:)

        super(**claim, graph_digest:)
      end
    end

    class ReviewOpened
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "review_opened"
    end
  end
end
