# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A cut names its seam, the turn it was committed on, the arm that
      # collapsed it, its kind, and at least one range it collapsed: an advance
      # that collapsed nothing new moved no seam, and is not a cut. A range's
      # content may be EMPTY -- that is a range whose collapse answered DROP,
      # and the cut must still say it collapsed, or a held render would retain
      # those turns.
      #
      # An advance supersedes nothing, since the cuts it moves past still hold
      # beneath it; a collapse re-writes at least two held cuts as one, or it
      # collapsed nothing together.
      class CompactionCut < Declarative::Carrier
        KINDS = %w[advance collapse handoff].freeze

        attribute :digest
        attribute :head
        attribute :strategy
        attribute :kind
        attribute :parent
        attribute :supersedes
        attribute :collapses
        attribute :plan_step_completions
        validates :digest, presence: { message: "must name the source turn the compaction collapsed up to, got nil" }
        validates :head, presence: { message: "must name the source head the cut was committed at, got nil" }
        validates :strategy, presence: { message: "must name the arm that collapsed the cut, got nil" }
        validates :kind, inclusion: { in: KINDS, message: "must be one of #{KINDS.join(", ")}, got %<value>s" }
        validates :collapses, presence: { message: "must name at least one collapsed range" }
        validates :plan_step_completions, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
        validate :collapses_name_span_and_content
        validate :supersedes_fits_kind

        private

        def collapses_name_span_and_content
          return if Array(collapses).all? { |collapse| collapse?(collapse) }

          errors.add(:collapses, "must each be a [first, last] span and the content blocks that replaced it")
        end

        def collapse?(collapse)
          collapse.is_a?(Hash) && collapse["span"].is_a?(Array) && collapse["span"].size == 2 &&
            collapse["content"].is_a?(Array)
        end

        def supersedes_fits_kind
          return errors.add(:supersedes, "must be a list of cut addresses, got #{supersedes.inspect}") unless addresses?
          return errors.add(:supersedes, "is not empty, but an advance supersedes no cut") if advance_superseding?

          errors.add(:supersedes, "names #{supersedes.size}, but a collapse supersedes at least two cuts") if thin?
        end

        def addresses? = supersedes.is_a?(Array) && supersedes.all?(String)

        def advance_superseding? = kind == "advance" && !supersedes.empty?

        def thin? = kind == "collapse" && supersedes.size < 2
      end
    end

    # One committed compaction cut: the SEAM it froze and what it froze there.
    #
    # `digest` is the source turn the compaction collapsed up to, and `head` the
    # turn the committing render stood on ({Event.stands_on}): the model's own
    # turn at the head, or the turn beneath a user turn the render added, since
    # an ask refused before any model saw it withdraws that prompt. A cut holds
    # only while the chain contains `head`: a rewind or a fork below it is a
    # forward run from there, and must be sent as one, not with a summary
    # committed later in time.
    #
    # `collapses` carries ranges with their replacements, and the replacement
    # is the point: a model-backed summary lives in an in-memory memo that
    # forgets a failure and does not survive the process, so it is the one part
    # of a cut a resume cannot recompute. Every range is over SOURCE turns,
    # whatever the summarizer was shown.
    #
    # `kind` says what the cut did to the cuts beneath it. An `advance` carries
    # only the ranges it NEWLY collapsed; the earlier ones are its `parent`'s,
    # so a seam is its lineage's ranges read root first, and a record's size
    # stays flat over a long session. A `collapse` re-summarizes held
    # replacements where they stand, and `supersedes` names the cuts whose
    # ranges it carries instead, so a held render folds those out of the
    # lineage. A `handoff` replaces the history before the current ask.
    #
    # Cuts are named by their content {#address} -- never by source digest,
    # which a retreat and a re-advance can reuse with different summary text,
    # and which a collapse shares with the last cut it supersedes. A child is
    # committed while its parent holds, so whenever a child's head is on a
    # chain its whole parent chain is too.
    #
    # `strategy` is the arm's name, so a prefix one arm collapsed is never held
    # under another. `plan_step_completions` is the session's count when the
    # cut committed: a commit consumes every plan step completed so far, and a
    # resume reads that here rather than firing a consumed step again.
    #
    # Written by {Session#record_compaction_cut} once per commit, and folded
    # back by {SessionRecord::Replay}.
    CompactionCut = Data.define(:digest, :head, :strategy, :kind, :parent, :supersedes, :collapses,
                                :plan_step_completions) do
      include Journalable

      # Normalized BEFORE the check, so a record read back from JSON (String
      # keys) and one built in-process (either) are the same value, render the
      # same bytes, and sit at the same address.
      def initialize(digest:, head:, strategy:, kind:, parent:, supersedes:, collapses:, plan_step_completions:)
        collapses = Canonical.normalize(collapses)
        Carriers::CompactionCut.check!(digest:, head:, strategy:, kind:, parent:, supersedes:, collapses:,
                                       plan_step_completions:)

        super(digest: -digest.to_s, head: -head.to_s, strategy: -strategy.to_s, kind: -kind,
              parent: parent&.then { -_1.to_s }, supersedes: supersedes.map(&:-@).freeze,
              collapses:, plan_step_completions: Integer(plan_step_completions))
      end

      # @return [Array<Array(String, String)>] each newly collapsed range's endpoints
      def spans = collapses.map { |collapse| collapse.fetch("span") }

      # The record's content address, which a child's `parent` names.
      #
      # @return [String]
      def address = Canonical.digest(to_journal)
    end
  end
end
