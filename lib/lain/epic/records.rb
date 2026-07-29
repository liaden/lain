# frozen_string_literal: true

module Lain
  module Epic
    # What can happen TO a stage, as opposed to what a stage is. Closed and
    # ordered the way {STAGES} and {STORED_STATUSES} are, and for the same
    # reason: `event` is folded on, so a fourth spelling nobody expects would
    # read as neither started nor completed and silently contribute nothing.
    STAGE_EVENTS = %w[started completed].freeze

    # Construction contracts for the two journal records, in the unit's own
    # validate-then-freeze convention: a throwaway {Lain::Guard} checked BEFORE
    # the auto-frozen Data value exists, so neither record ever touches
    # ActiveModel and both stay `Ractor.shareable?`.
    #
    # These same guards are what {Epic::Progress} re-checks each journaled
    # record against on the way back IN. A record that cannot be read whole must
    # abort the fold rather than be skipped, so the shape a write refuses and
    # the shape a read refuses have to be one declaration.
    module Guards
      # A transition must name the epic it belongs to and the issue it moves,
      # and both sides of the move must be statuses an issue may CARRY --
      # `ready` is derived from the blocks graph and no transition can arrive at
      # it (see {DERIVED_STATUSES}).
      class IssueTransition < Guard
        attribute :epic_slug
        attribute :issue_id
        attribute :from_status
        attribute :to_status
        validates :epic_slug, presence: { message: "must name the epic this transition belongs to, got nil" }
        validates :issue_id, presence: { message: "must name the issue that moved, got nil" }
        validates :from_status, inclusion: { in: STORED_STATUSES,
                                             message: "must be one of #{STORED_STATUSES.join("/")}, " \
                                                      "got %<value>s" }
        validates :to_status, inclusion: { in: STORED_STATUSES,
                                           message: "must be one of #{STORED_STATUSES.join("/")}, got %<value>s" }
      end

      # `stage` is absent here on purpose: {Stage} owns the closed pipeline set
      # and refuses an unknown name as an {UnknownStage}, which is a Lain::Error
      # exe/lain renders. Restating the membership test would be a second copy
      # of STAGES waiting to disagree with the first.
      class StageTransition < Guard
        attribute :epic_slug
        attribute :event
        validates :epic_slug, presence: { message: "must name the epic this transition belongs to, got nil" }
        validates :event, inclusion: { in: STAGE_EVENTS,
                                       message: "must be one of #{STAGE_EVENTS.join("/")}, got %<value>s" }
      end
    end

    # One issue's status change, journaled. This record -- not the markdown
    # document -- is the runtime truth {Progress} folds: the document is what an
    # author wrote, and a status in it goes stale the moment work starts.
    #
    # `from_status` is carried alongside `to_status` even though the fold only
    # ever reads the latter. It is what makes one line legible on its own (a
    # reader tailing the journal sees a MOVE, not a level) and what lets a later
    # audit notice two writers disagreeing about where an issue was.
    #
    # Everything is interned, so the whole value is Ractor-shareable and the
    # repeated keys (slug, id, statuses) cost one String each per run.
    IssueTransition = Data.define(:epic_slug, :issue_id, :from_status, :to_status) do
      include Telemetry::Journalable

      def initialize(epic_slug:, issue_id:, from_status:, to_status:)
        # Interned BEFORE the guard, so `presence:` judges the bytes that get
        # journaled: an id object whose #to_s is blank passes a presence check on
        # the raw object and then names an issue no fold can match back.
        epic_slug = -epic_slug.to_s
        issue_id = -issue_id.to_s.strip
        from_status = -from_status.to_s
        to_status = -to_status.to_s
        Guards::IssueTransition.check!(epic_slug:, issue_id:, from_status:, to_status:)

        super
      end
    end

    # Reopened rather than declared inside the `Data.define ... do` block: a
    # constant there is lexically scoped to the enclosing MODULE, not the Data
    # class (the pinned Ruby trap {Request::SYSTEM_PREFIX} records).
    class IssueTransition
      # The discriminator {Journalable} derives from this class's own name,
      # pinned as a constant so readers name it once and a rename breaks loudly
      # at the constant instead of quietly re-labelling records nobody can join
      # anymore -- {Approval::SignoffQueue::JOURNAL_TYPE}'s reasoning, and a
      # spec pins the two spellings equal.
      JOURNAL_TYPE = "issue_transition"
    end

    # One stage boundary crossed, journaled. Paired `started`/`completed` events
    # rather than a single "current stage" record, because a stage that started
    # and a stage that finished are different facts and an epic can sit in
    # either state for days.
    StageTransition = Data.define(:epic_slug, :stage, :event) do
      include Telemetry::Journalable

      def initialize(epic_slug:, stage:, event:)
        epic_slug = -epic_slug.to_s
        # Through Stage, so the closed pipeline set is asserted once and a
        # {Stage} value is accepted as readily as its name -- both answer #to_s.
        stage = Stage.new(stage.to_s).name
        event = -event.to_s
        Guards::StageTransition.check!(epic_slug:, event:)

        super
      end
    end

    class StageTransition
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "stage_transition"
    end
  end
end
