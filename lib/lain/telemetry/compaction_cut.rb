# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A cut names its seam, the head it was committed at, the arm that
      # collapsed it, and at least one range it NEWLY collapsed: an advance that
      # collapsed nothing new moved no seam, and is not a cut. A range's content
      # may be EMPTY -- that is a range whose collapse answered DROP, and the cut
      # must still say it collapsed, or a held render would retain those turns.
      class CompactionCut < Declarative::Carrier
        attribute :digest
        attribute :head
        attribute :strategy
        attribute :parent
        attribute :collapses
        attribute :plan_step_completions
        validates :digest, presence: { message: "must name the source turn the compaction collapsed up to, got nil" }
        validates :head, presence: { message: "must name the source head the cut was committed at, got nil" }
        validates :strategy, presence: { message: "must name the arm that collapsed the cut, got nil" }
        validates :collapses, presence: { message: "must name at least one collapsed range" }
        validates :plan_step_completions, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
        validate :collapses_name_span_and_content

        private

        def collapses_name_span_and_content
          return if Array(collapses).all? { |collapse| collapse?(collapse) }

          errors.add(:collapses, "must each be a [first, last] span and the content blocks that replaced it")
        end

        def collapse?(collapse)
          collapse.is_a?(Hash) && collapse["span"].is_a?(Array) && collapse["span"].size == 2 &&
            collapse["content"].is_a?(Array)
        end
      end
    end

    # One committed compaction advance: the SEAM it froze and what it froze
    # there.
    #
    # `digest` is the source turn the compaction collapsed up to, and `head` the
    # source head it was committed at. A cut holds only while the head's chain
    # contains `head`: a rewind or a fork below it is a forward run from there,
    # and must be sent as one, not with a summary committed later in time.
    #
    # `collapses` carries the ranges THIS advance newly collapsed, each with its
    # replacement, and the replacement is the point: a model-backed summary
    # lives in an in-memory memo that forgets a failure and does not survive
    # the process, so it is the one part of a cut a resume cannot recompute.
    # The ranges an earlier advance collapsed are its `parent`'s, named by that
    # record's content {#address} -- never by its source digest, which a
    # retreat and a re-advance can reuse with different summary text. A child
    # is committed while its parent holds, so whenever a child's head is on a
    # chain its whole parent chain is too, and a seam is its lineage's ranges
    # read root first. Carrying only the delta keeps a record's size flat over a
    # long session rather than growing with every advance.
    #
    # `strategy` is the arm's name, so a prefix one arm collapsed is never held
    # under another. `plan_step_completions` is the session's count when the
    # cut committed: a commit consumes every plan step completed so far, and a
    # resume reads that here rather than firing a consumed step again.
    #
    # Written by {Session#record_compaction_cut} once per advance, and folded
    # back by {SessionRecord::Replay}.
    CompactionCut = Data.define(:digest, :head, :strategy, :parent, :collapses, :plan_step_completions) do
      include Journalable

      # Normalized BEFORE the check, so a record read back from JSON (String
      # keys) and one built in-process (either) are the same value, render the
      # same bytes, and sit at the same address.
      def initialize(digest:, head:, strategy:, parent:, collapses:, plan_step_completions:)
        collapses = Canonical.normalize(collapses)
        Carriers::CompactionCut.check!(digest:, head:, strategy:, parent:, collapses:, plan_step_completions:)

        super(digest: -digest.to_s, head: -head.to_s, strategy: -strategy.to_s, parent: parent&.then { -_1.to_s },
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
