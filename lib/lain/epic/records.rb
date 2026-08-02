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

    # Construction contracts for the unit's journal records, in its own
    # validate-then-freeze convention: a throwaway {Lain::Guard} checked BEFORE
    # the auto-frozen Data value exists, so no record ever touches ActiveModel
    # and all of them stay `Ractor.shareable?`.
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

      # A revision must name the epic it revised, an operation something can
      # replay, and the two digests that are its oracle. Its ARGUMENTS are not restated here:
      # {Epic::GraphFiber} refuses a payload it could not replay at its own
      # construction, and a second copy of that contract beside the journal is
      # exactly the drift {Guards} exists to prevent -- so this guard reads
      # {REVISION_OPS} rather than a list of its own.
      class GraphRevision < Guard
        attribute :epic_slug
        attribute :operation
        attribute :before
        attribute :after
        validates :epic_slug, presence: { message: "must name the epic this revision belongs to, got nil" }
        validates :operation, inclusion: { in: REVISION_OPS.keys,
                                           message: "must be one of #{REVISION_OPS.keys.join("/")}, got %<value>s" }
        validates :before, presence: { message: "must name the graph digest the revision started from, got nil" }
        validates :after, presence: { message: "must name the graph digest the revision landed on, got nil" }
      end

      # What both halves of a review claim carry, gathered because a review is
      # ONE fact told twice: the same epic, the same file, the same generation,
      # and the same address for the bytes lain wrote. Two copies of these four
      # rules would be two things that can drift, and a `review_closed` whose
      # generation is judged more loosely than its `review_opened` is exactly
      # the record {Review::Replay} cannot pair back up.
      class ReviewRecord < Guard
        attribute :epic_slug
        attribute :path
        attribute :generation
        attribute :written_digest
        validates :epic_slug, presence: { message: "must name the epic this review belongs to, got nil" }
        validates :path, presence: { message: "must name the file the review holds, got nil" }
        # The generation is a KEY -- the editor stamps it on a buffer and hands
        # it back to settle -- so zero and nil are refused rather than tolerated:
        # both are what a missing field coerces to, and a review keyed on the
        # absence of a generation is one no `done` gesture can ever match.
        #
        # A record BUILT here never reaches this message: {WireInteger} refuses
        # the same values earlier and more tersely, because the write side has
        # to read the wire's `"3"` before it can store one. The declaration is
        # for the READ side, which re-checks a journaled record whose generation
        # is already an Integer -- and that is the whole point of one guard
        # serving both.
        validates :generation, numericality: { only_integer: true, greater_than: 0,
                                               message: "must be the positive integer identifying this " \
                                                        "review, got %<value>s" }
        validates :written_digest, presence: { message: "must digest the bytes lain wrote, got nil" }
      end

      # A review claim also names the GRAPH lain wrote, which the settlement
      # does not: the claim is what a later reader joins to "which graph was on
      # disk when the human took it", while the settlement's second address is
      # the disk's.
      # `graph_digest` is deliberately UNVALIDATED for presence: nil is the
      # honest address of a prose artifact's graph, and {Intake::Prose} is the
      # written side that supplies it. A presence check here would make the
      # three prose stages unreviewable -- the review would raise inside the
      # journal write, before any baseline was ever chosen.
      class ReviewOpened < ReviewRecord
        attribute :graph_digest
      end

      # A settlement reports the comparison, so its own three members are the
      # ones a comparison produces.
      class ReviewClosed < ReviewRecord
        attribute :disk_digest
        attribute :changes
        attribute :lossy
        attribute :error
        attribute :error_kind
        validates :disk_digest, presence: { message: "must digest the bytes that came back, got nil" }
        # One measure, one boolean. `presence:` cannot express it -- `false` is
        # the answer the predicate gives most often and would fail a presence
        # check -- and a lossy field holding a String would journal a suspicion
        # nobody can read as one.
        validates :lossy, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validate :changes_are_an_account_summary
        validate :error_and_kind_travel_together

        private

        def changes_are_an_account_summary
          return if changes.is_a?(Hash)

          errors.add(:changes, "must be the account's changed kinds as a Hash, got #{changes.inspect}")
        end

        # {Intake::Delta}'s own pairing rule, restated where the record is built:
        # a message with no kind cannot be told from a grammar refusal, and a
        # kind with no message says nothing at all.
        def error_and_kind_travel_together
          return if error.nil? == error_kind.nil?

          errors.add(:error, "and its kind are named together, got #{error.inspect} and #{error_kind.inspect}")
        end
      end

      # One note a human left on a document under review. The guard is about the
      # two things nobody could reconstruct afterwards -- what they wrote, and
      # what they wrote it ON -- plus the two keys that place it.
      #
      # `issue_id` is declared and deliberately UNVALIDATED, {ReviewOpened}'s
      # `graph_digest` rule: nil is the honest attribution for a note in the
      # preamble, which encloses no issue, and for a note whose anchor drifted,
      # where the line number is no longer evidence of which issue was meant.
      class Annotation < Guard
        attribute :epic_slug
        attribute :generation
        attribute :issue_id
        attribute :line
        attribute :anchor_text
        attribute :text
        attribute :drifted
        validates :epic_slug, presence: { message: "must name the epic this note belongs to, got nil" }
        # Both keys read the READ side's way, for {ReviewRecord}'s reason.
        validates :generation, numericality: { only_integer: true, greater_than: 0,
                                               message: "must be the review generation the note was left " \
                                                        "during, got %<value>s" }
        validates :line, numericality: { only_integer: true, greater_than: 0,
                                         message: "must be the document line the note points at, " \
                                                  "got %<value>s" }
        # `presence:` is exactly right for both: ActiveSupport reads a
        # whitespace-only String as blank, so a note the human typed nothing
        # into and a note anchored to a blank line are refused rather than
        # journaled as evidence of something.
        validates :anchor_text, presence: { message: "must carry the line the note was anchored to, got nil" }
        validates :text, presence: { message: "must carry what the human wrote, got nil" }
        # One measure, one boolean -- {ReviewClosed}'s `lossy` rule, and for its
        # reason: `false` is the answer most notes give.
        validates :drifted, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
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

    # One structural revision of an epic's issue graph, journaled: the
    # {Epic::GraphFiber} an operation yielded, plus the epic it belongs to --
    # which is the one thing the operation cannot supply, because a {Graph}
    # carries no slug. That is the whole difference between the two shapes, and
    # a spec pins the member lists equal so neither can grow a field the other
    # silently drops.
    #
    # Unlike its two siblings this record is a REPLAY PAYLOAD rather than a
    # report: `arguments` holds the arriving issues in {Issue#canonical} form, so
    # a reader can perform the edit again and check that it lands on `after`. It
    # is therefore normalized THROUGH the fiber -- one construction contract,
    # checked on the way into the journal here and on the way back out by
    # {GraphFiber.of}, rather than a second normalization that could disagree.
    GraphRevision = Data.define(:epic_slug, :operation, :arguments, :preimage, :results, :before, :after) do
      include Telemetry::Journalable

      def initialize(epic_slug:, operation:, arguments:, preimage:, results:, before:, after:)
        epic_slug = -epic_slug.to_s
        # The record's own guard first, so an out-of-range op reads as the
        # ArgumentError every other epic record raises rather than as the
        # MalformedGraph the fiber underneath would.
        Guards::GraphRevision.check!(epic_slug:, operation: -operation.to_s, before:, after:)
        super(epic_slug:, **GraphFiber.new(operation:, arguments:, preimage:, results:, before:, after:).to_h)
      end
    end

    class GraphRevision
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "graph_revision"
    end

    # A positive integer as it arrives off a wire, read strictly.
    #
    # Two fields need this, and both are KEYS: a review's `generation`, which an
    # editor stamps on a buffer and hands back, and an annotation's `line`, which
    # is where a note points. Every coercion Ruby offers is wrong for a key --
    # `"7abc".to_i` and `7.9.to_i` are both 7, `nil.to_i` is 0, and `Integer()`
    # truncates a Float the same way -- so a shallow reading names a review, or a
    # line, that nobody sent. There is one reader because there is one rule, and
    # the two fields drifting apart is how the shallow version came back.
    module WireInteger
      def self.read(value, field:)
        return value if value.is_a?(Integer) && value.positive?
        return value.to_i if value.is_a?(String) && value.match?(/\A[1-9][0-9]*\z/)

        raise ArgumentError, "#{field} must be a positive canonical integer, got #{value.inspect}"
      end
    end

    # The four members that identify a review, normalized to the bytes that get
    # stored. Both halves of a review carry them and both must read them the
    # same way, so this is one declaration rather than two -- {Guards::ReviewRecord}
    # is the same argument on the validation side.
    #
    # Everything is interned BEFORE its guard, the unit's usual order and for
    # its usual reason: a slug object whose `#to_s` is blank passes a naive
    # presence test and then names a partition nothing can match. `generation`
    # goes through {WireInteger} for the sharper version of that: it arrives off
    # a wire as msgpack or JSON, and a stored `"3"` beside a `3` would key a
    # review {Review#settle} -- which reads it the same way -- could never find.
    module ReviewClaim
      def self.interned(epic_slug:, path:, generation:, written_digest:)
        { epic_slug: -epic_slug.to_s, path: path(path), generation: generation(generation),
          written_digest: -written_digest.to_s }
      end

      def self.generation(value) = WireInteger.read(value, field: "generation")

      # The held path, normalized. PUBLIC because {Review} keys its live open set
      # on the same string this record stores, and the two normalizations must be
      # one: when they diverged, `open?` answered true live and false after a
      # restart for one path -- a guard that stops guarding without a word.
      def self.path(value) = -value.to_s.strip
    end

    # A human took a document, journaled by {Review#open} BEFORE the baton is
    # held. An INTENT and not an ack, the opposite of {DocWritten} and for the
    # opposite reason: a crash between the record and the live baton leaves a
    # claim that rebuilds as OPEN with nothing behind it, which refuses a write
    # the record would also have refused. Journaling second would lose the claim
    # instead, and a lost claim reads as "nobody is holding this".
    #
    # `path` is ABSOLUTE, which is the one place this unit departs from
    # {DocWritten}'s relative path, and it departs deliberately. A review is a
    # LIVE question about a file on this machine -- the exact string an editor
    # surface opens and the exact string {Home::Journaled}'s reviews duck is
    # asked about ({Home::Artifact#path}) -- and {Review.from_journal} rebuilds
    # the open set with nothing but these records, so a relative path here would
    # rebuild a baton that no `open?` can ever match. The durable, portable join
    # is `epic_slug` plus the two digests, which travel between machines exactly
    # as `doc_written`'s do.
    #
    # `generation` is the key the whole flow turns on: {Review#open} answers it,
    # the editor stamps it on the review buffer, and `done` hands it back. It is
    # unique within `epic_slug` and NOT within the journal -- two epics sharing
    # one journal both hand out 1, because each numbers from its own records and
    # there is deliberately no counter between them ({Review} says why).
    #
    # So the identity is the PAIR, and this record is where a reader learns it:
    # a `generation` read off one of these lines means nothing without the
    # `epic_slug` on the same line, and a settle route must carry both. Given
    # both, the stale-buffer guarantee holds -- a buffer left over from a dead
    # process names a generation that is settled or unknown within its own epic,
    # never one that now belongs to another review.
    ReviewOpened = Data.define(:epic_slug, :path, :generation, :written_digest, :graph_digest) do
      include Telemetry::Journalable

      # `graph_digest` defaults to nil and is interned with `&&=`, exactly as
      # {DocWritten} does and for its reason: three of the four stages are
      # prose, which has no graph to address, so a review opened over one
      # journals the byte address alone. A bare `-graph_digest.to_s` would turn
      # that nil into `""` -- an address-shaped string addressing nothing.
      def initialize(epic_slug:, path:, generation:, written_digest:, graph_digest: nil)
        claim = ReviewClaim.interned(epic_slug:, path:, generation:, written_digest:)
        graph_digest &&= -graph_digest.to_s
        Guards::ReviewOpened.check!(**claim, graph_digest:)

        super(**claim, graph_digest:)
      end
    end

    class ReviewOpened
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "review_opened"
    end

    # The human handed the document back, journaled by {Review#settle} before
    # the baton is released and before any fiber is woken -- so a reader woken
    # by the delta can trust the record is already there.
    #
    # It carries the whole of what {Intake::Delta} reports, in the delta's own
    # two registers. The BYTE register is `written_digest` and `disk_digest`:
    # equal means the bytes never moved. The MEANING register is `changes`, the
    # account's changed kinds and their ids, which is exact and unhedged -- an
    # id under `removed` LEFT, no threshold involved.
    #
    # `lossy` is neither register and must not be read as one. It says only that
    # the disk came back at less than half the bytes lain wrote -- a suspicion of
    # truncation that a legitimate mass edit trips too. It is emphatically NOT
    # "issues were deleted"; that is `changes["removed"]`.
    #
    # `error` and `error_kind` are the delta's parse failure, kept together for
    # {Intake::Delta}'s reason. They are what stops an empty `changes` from
    # meaning two different things: with an error present, nothing was COMPARED,
    # which is a different fact from "the two sides agreed".
    #
    # An `error_kind` of `Lain::Epic::Review::Unrecoverable` is the one value
    # that changes how the rest of the line reads, and a reader joining these
    # records has no other way to know it. It means lain restarted while the
    # human held the document, so the bytes it wrote are gone and NOTHING was
    # compared -- the file is not corrupt, and a surface must not say it is.
    # Under it, `changes` is empty because there was no comparison, and
    # `lossy` is `false` because the ratio was never MEASURED (the written
    # bytesize is not on record), not because truncation was ruled out.
    #
    # The summary is string-keyed because it makes a round trip through JSON and
    # a record read back has to equal the one written -- {Account#changes}
    # answers Symbol keys, and Symbol and String keys are two spellings of one
    # journal field.
    ReviewClosed = Data.define(:epic_slug, :path, :generation, :written_digest, :disk_digest, :changes,
                               :lossy, :error, :error_kind) do
      include Telemetry::Journalable

      def initialize(epic_slug:, path:, generation:, written_digest:, disk_digest:, changes:, lossy:,
                     error: nil, error_kind: nil)
        claim = ReviewClaim.interned(epic_slug:, path:, generation:, written_digest:)
        disk_digest = -disk_digest.to_s
        # `&&=`, so an absent error stays absent rather than interning to "" --
        # {Intake::Delta} reads a present error as "nothing was compared", and a
        # blank one would say that about every settlement that went fine.
        error &&= -error.to_s
        error_kind &&= -error_kind.to_s
        Guards::ReviewClosed.check!(**claim, disk_digest:, changes:, lossy:, error:, error_kind:)

        # `changes` is normalized AFTER its guard rather than before it, the one
        # departure from {ReviewClaim}'s order and a forced one: the guard's
        # question is whether the summary is a Hash at all, and the
        # normalization cannot run on a value that is not one. It preserves
        # every key it touches, so the guard still judges what gets stored.
        super(**claim, disk_digest:, changes: summarized(changes), lossy:, error:, error_kind:)
      end

      private

      # Every level frozen, prose and ids included: `Data` freezes the instance
      # and nothing else, so a nested Array left mutable would cost this value
      # `Ractor.shareable?` -- the mechanical statement that a journaled record
      # holds no reachable mutable state.
      def summarized(changes)
        changes.to_h { |kind, ids| [-kind.to_s, ids.map { |id| -id.to_s }.freeze] }.freeze
      end
    end

    class ReviewClosed
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "review_closed"
    end

    # Normalization for {Annotation}, in the unit's intern-then-guard order and
    # through the unit's own guard: a bespoke validator here could not be
    # re-checked by a reader folding these records back in, which is the whole
    # bargain {Guards} strikes.
    module AnnotationValue
      def self.interned(epic_slug:, generation:, issue_id:, line:, anchor_text:, text:, drifted: false)
        values = { epic_slug: -epic_slug.to_s, generation: ReviewClaim.generation(generation),
                   issue_id: issue_id && -issue_id.to_s.strip, line: WireInteger.read(line, field: "line"),
                   anchor_text: -anchor_text.to_s, text: -text.to_s, drifted: }
        Guards::Annotation.check!(**values)

        values
      end
    end

    # One note a human left on a document while they held it, journaled by
    # {Review#settle} beside the settlement it belongs to.
    #
    # It is the only epic record carrying a human's own words, which is what
    # decides everything else about it. `text` is unreconstructable, so a note is
    # never dropped once it exists. `anchor_text` is the line the note was
    # placed on AT THE TIME, kept beside `line` because the two can disagree: an
    # extmark slides as the human keeps editing, so the number can end up naming
    # a line they never pointed at.
    #
    # `drifted` is that disagreement, said out loud. Under it, `issue_id` is nil
    # -- not because the note belongs to no issue, but because the line number is
    # no longer evidence of which one, and guessing from it would be a reading
    # dressed up as a fact. A reader that wants the note back where it belongs
    # searches for `anchor_text`; nothing here does that for it.
    #
    # `issue_id` is nil for a preamble note too, which is a DIFFERENT fact --
    # that note is attributed to nothing because there was nothing above it to
    # attribute it to. `drifted` is what tells the two apart.
    Annotation = Data.define(:epic_slug, :generation, :issue_id, :line, :anchor_text, :text, :drifted) do
      include Telemetry::Journalable

      def initialize(**values) = super(**AnnotationValue.interned(**values))
    end

    class Annotation
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "annotation"
    end
  end
end
