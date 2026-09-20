# frozen_string_literal: true

module Lain
  module Epic
    # Construction contracts for the unit's journal records: a throwaway
    # {Lain::Declarative::Carrier} checked BEFORE the auto-frozen Data value
    # exists, so no record ever touches ActiveModel and all stay
    # `Ractor.shareable?`.
    #
    # {Epic::Progress} re-checks each journaled record against these same
    # contracts on the way back IN. A record that cannot be read whole must abort
    # the fold rather than be skipped, so the shape a write refuses and the shape
    # a read refuses have to be one declaration.
    module Contracts
      # Both sides of the move must be statuses an issue may CARRY -- `ready` is
      # derived from the blocks graph and no transition can arrive at it (see
      # {DERIVED_STATUSES}).
      class IssueTransition < Declarative::Carrier
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
      # and refuses an unknown name as {UnknownStage}. Restating the membership
      # test would be a second copy of STAGES waiting to disagree with the first.
      class StageTransition < Declarative::Carrier
        attribute :epic_slug
        attribute :event
        validates :epic_slug, presence: { message: "must name the epic this transition belongs to, got nil" }
        validates :event, inclusion: { in: STAGE_EVENTS,
                                       message: "must be one of #{STAGE_EVENTS.join("/")}, got %<value>s" }
      end

      # `graph_digest` is absent here on purpose: only an epic write has a graph,
      # so it is the one member a valid record may omit.
      class DocWritten < Declarative::Carrier
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

      # The revision's ARGUMENTS are deliberately not restated: {Epic::GraphFiber}
      # refuses a payload it could not replay at its own construction, and a
      # second copy of that contract beside the journal is exactly the drift
      # {Contracts} exists to prevent -- so this reads {REVISION_OPS} rather than
      # a list of its own.
      class GraphRevision < Declarative::Carrier
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
      # ONE fact told twice. Two copies of these four rules would be two things
      # that can drift, and a `review_closed` whose generation is judged more
      # loosely than its `review_opened` is exactly the record {Review::Replay}
      # cannot pair back up.
      class ReviewRecord < Declarative::Carrier
        attribute :epic_slug
        attribute :path
        attribute :generation
        attribute :written_digest
        validates :epic_slug, presence: { message: "must name the epic this review belongs to, got nil" }
        validates :path, presence: { message: "must name the file the review holds, got nil" }
        # The generation is a KEY, so zero and nil are refused rather than
        # tolerated: both are what a missing field coerces to, and a review keyed
        # on the absence of a generation is one no `done` gesture can match.
        #
        # A record BUILT here never reaches this message -- {WireInteger} refuses
        # the same values earlier and more tersely. The declaration is for the
        # READ side, which re-checks a journaled record whose generation is
        # already an Integer, and that is the point of one contract serving both.
        validates :generation, numericality: { only_integer: true, greater_than: 0,
                                               message: "must be the positive integer identifying this " \
                                                        "review, got %<value>s" }
        validates :written_digest, presence: { message: "must digest the bytes lain wrote, got nil" }
      end

      # A review claim also names the GRAPH lain wrote, which the settlement does
      # not: the claim is what a later reader joins to "which graph was on disk
      # when the human took it". `graph_digest` is deliberately UNVALIDATED for
      # presence -- nil is the honest address of a prose artifact's graph, and a
      # presence check here would make the three prose stages unreviewable, the
      # review raising inside the journal write before any baseline was chosen.
      class ReviewOpened < ReviewRecord
        attribute :graph_digest
      end

      # A settlement reports the comparison, so its own members are the ones a
      # comparison produces.
      class ReviewClosed < ReviewRecord
        attribute :disk_digest
        attribute :changes
        attribute :lossy
        attribute :error
        attribute :error_kind
        validates :disk_digest, presence: { message: "must digest the bytes that came back, got nil" }
        # `presence:` cannot express this -- `false` is the answer the predicate
        # gives most often and would fail a presence check -- and a lossy field
        # holding a String would journal a suspicion nobody can read as one.
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

      # `issue_id` is declared and deliberately UNVALIDATED, on {ReviewOpened}'s
      # `graph_digest` rule: nil is the honest attribution for a note in the
      # preamble, which encloses no issue, and for a note whose anchor drifted,
      # where the line number is no longer evidence of which issue was meant.
      class Annotation < Declarative::Carrier
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
        # whitespace-only String as blank, so a note the human typed nothing into
        # and a note anchored to a blank line are refused rather than journaled
        # as evidence of something.
        validates :anchor_text, presence: { message: "must carry the line the note was anchored to, got nil" }
        validates :text, presence: { message: "must carry what the human wrote, got nil" }
        # {ReviewClosed}'s `lossy` rule, and for its reason: `false` is the
        # answer most notes give, and a presence check would refuse it.
        validates :drifted, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end
    end
  end
end
