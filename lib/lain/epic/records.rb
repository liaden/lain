# frozen_string_literal: true

module Lain
  module Epic
    # What can happen TO a stage, as opposed to what a stage is. Closed and
    # ordered the way {STAGES} and {STORED_STATUSES} are, and for the same
    # reason: `event` is folded on, so a fourth spelling nobody expects would
    # read as neither started nor completed and silently contribute nothing.
    STAGE_EVENTS = %w[started completed].freeze

    # The four artifacts a {Home} holds, as the journal names them. Closed for
    # {STAGE_EVENTS}' reason and one more: a reader joining a `doc_written`
    # record back to a file has to know which of the four layouts the path came
    # from, and a fifth spelling nobody expects would join to nothing.
    DOC_KINDS = %w[research epic issue plan].freeze

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

      # A write ack must name the epic, the artifact inside it, and the bytes
      # that landed. `graph_digest` is absent here on purpose: only an epic
      # write has a graph, so it is the one member a valid record may omit.
      class DocWritten < Guard
        attribute :epic_slug
        attribute :kind
        attribute :path
        attribute :byte_digest
        validates :epic_slug, presence: { message: "must name the epic this artifact belongs to, got nil" }
        validates :kind, inclusion: { in: DOC_KINDS,
                                      message: "must be one of #{DOC_KINDS.join("/")}, got %<value>s" }
        validates :path, presence: { message: "must name the artifact inside the epic home, got nil" }
        validates :byte_digest, presence: { message: "must digest the bytes that landed, got nil" }
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

    # One artifact landed on disk, journaled by {Home::Journaled} AFTER the
    # write returns. An ack and never an intent: a record here means those bytes
    # were on disk, so a reader may join `byte_digest` to the file and expect
    # them to match until the next write of the same path. The converse does not
    # hold -- see {Home::Journaled} for why a missing record proves nothing.
    #
    # `path` is relative to the epic home rather than absolute. An epic home
    # moves with `$XDG_STATE_HOME` and travels between machines when it lives in
    # the repo, so an absolute path pinned here would stop naming the artifact
    # it describes; relative to the home, the join survives both.
    #
    # `byte_digest` addresses the RAW BYTES through {Workspace::Snapshot::Blob},
    # which is the same address the reviewed-document side computes -- one
    # document, one address, whichever side of the review it is seen from. It is
    # recomputed with exactly:
    #
    #   Workspace::Snapshot::Blob.new(bytes: File.binread(path)).digest
    #
    # and with nothing else. In particular it is NOT `b3sum <file>`: Blob
    # domain-separates with a git-style `blob <size>\0` header so file content
    # cannot collide with the JSON-canonical digests every other Store object
    # uses. It is also NOT {Canonical.digest}, which would hash
    # `JSON.generate(content)` -- injective, so the join would work, but no
    # reader holding the bytes would ever arrive at the number, and Canonical
    # pins UTF-8 where a file is arbitrary bytes.
    #
    # `graph_digest` is the epic write's second address: the same bytes can be
    # re-emitted from an equal graph, and a reader auditing "which graph is on
    # disk" wants the graph's own content address rather than a re-parse. It is
    # nil for the three artifacts that are prose, not a graph, and the writer
    # makes that structural -- a graph digest is a property of the resolved
    # artifact, so prose has no way to acquire one.
    DocWritten = Data.define(:epic_slug, :kind, :path, :byte_digest, :graph_digest) do
      include Telemetry::Journalable

      def initialize(epic_slug:, kind:, path:, byte_digest:, graph_digest: nil)
        epic_slug = -epic_slug.to_s
        kind = -kind.to_s
        path = -path.to_s.strip
        byte_digest = -byte_digest.to_s
        # `&&=`, so an absent graph stays absent rather than interning to "" --
        # a blank digest would read as a graph nothing can match.
        graph_digest &&= -graph_digest.to_s
        Guards::DocWritten.check!(epic_slug:, kind:, path:, byte_digest:)

        super
      end
    end

    class DocWritten
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "doc_written"
    end
  end
end
