# frozen_string_literal: true

module Lain
  module Epic
    # One issue's status change, journaled. This record -- not the markdown
    # document -- is the runtime truth {Progress} folds: the document is what an
    # author wrote, and a status in it goes stale the moment work starts.
    #
    # `from_status` is carried alongside `to_status` even though the fold only
    # reads the latter: it makes one line legible on its own (a reader tailing
    # the journal sees a MOVE, not a level) and lets a later audit notice two
    # writers disagreeing about where an issue was.
    IssueTransition = Data.define(:epic_slug, :issue_id, :from_status, :to_status) do
      include Telemetry::Journalable

      def initialize(epic_slug:, issue_id:, from_status:, to_status:)
        # Interned BEFORE the contract, so `presence:` judges the bytes that get
        # journaled: an id object whose #to_s is blank passes a presence check on
        # the raw object and then names an issue no fold can match back. The
        # interning also keeps the value `Ractor.shareable?`.
        epic_slug = -epic_slug.to_s
        issue_id = -issue_id.to_s.strip
        from_status = -from_status.to_s
        to_status = -to_status.to_s
        Contracts::IssueTransition.check!(epic_slug:, issue_id:, from_status:, to_status:)

        super
      end
    end

    class IssueTransition
      # Reopened rather than declared inside the `Data.define ... do` block: a
      # constant there is lexically scoped to the enclosing MODULE, not the Data
      # class (the pinned Ruby trap {Request::SYSTEM_PREFIX} records).

      # The discriminator {Journalable} derives from this class's own name,
      # pinned as a constant so a rename breaks loudly here instead of quietly
      # re-labelling records nobody can join any more. A spec pins the two
      # spellings equal.
      JOURNAL_TYPE = "issue_transition"
    end
  end
end
