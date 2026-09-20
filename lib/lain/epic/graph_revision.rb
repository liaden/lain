# frozen_string_literal: true

module Lain
  module Epic
    # One structural revision of an epic's issue graph: the {Epic::GraphFiber} an
    # operation yielded, plus the epic slug -- the one thing the operation cannot
    # supply, because a {Graph} carries none. That is the whole difference
    # between the two shapes, and a spec pins the member lists equal so neither
    # can grow a field the other silently drops.
    #
    # Unlike its siblings this record is a REPLAY PAYLOAD rather than a report:
    # `arguments` holds the arriving issues in {Issue#canonical} form, so a
    # reader can perform the edit again and check that it lands on `after`. It is
    # therefore normalized THROUGH the fiber -- one construction contract,
    # checked into the journal here and back out by {GraphFiber.of}, rather than
    # a second normalization that could disagree.
    GraphRevision = Data.define(:epic_slug, :operation, :arguments, :preimage, :results, :before, :after) do
      include Telemetry::Journalable

      def initialize(epic_slug:, operation:, arguments:, preimage:, results:, before:, after:)
        epic_slug = -epic_slug.to_s
        # The record's own contract first, so an out-of-range op reads as the
        # ArgumentError every other epic record raises rather than as the
        # MalformedGraph the fiber underneath would.
        Contracts::GraphRevision.check!(epic_slug:, operation: -operation.to_s, before:, after:)
        super(epic_slug:, **GraphFiber.new(operation:, arguments:, preimage:, results:, before:, after:).to_h)
      end
    end

    class GraphRevision
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "graph_revision"
    end
  end
end
