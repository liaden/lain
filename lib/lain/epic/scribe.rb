# frozen_string_literal: true

module Lain
  module Epic
    # The epic tier's one write path: {IssueTransition} and {StageTransition}
    # already refuse a bad shape at construction (see {Contracts} in
    # records.rb), and nothing else in lib constructs either record
    # (`scribe_write_side_spec.rb` pins it), so the write-side contract is
    # checked in exactly one place. {Progress.fold} re-checks those contracts on
    # the way back in and additionally judges what the write side structurally
    # cannot: graph membership (`Lineage`) and byte-exact slug equality
    # (`Refold#mine?`). A refusal happens before `@journal <<` -- both records
    # validate before `Data`'s own `super` freezes the value -- so it never
    # reaches the journal.
    class Scribe
      # `epic_slug` goes through {Home.checked_name}, not merely a presence
      # check. The transition contracts only demand a non-blank string, but
      # `Refold#mine?` partitions journaled records on byte-exact equality
      # against the slug a caller names to {Progress.fold}, and that slug always
      # came from a real {Home}. A Scribe built on " demo" or "Demo" passes the
      # transition's own contract, writes happily, and then partitions as SOMEONE
      # ELSE'S epic -- dropped as foreign rather than refused, so the transition
      # never folds in, silently, in an append-only file, and {ForeignJournal}
      # fires only when EVERY record shares the bad slug. `journal` is checked
      # for {Progress}'s reason: built on `journal: nil` a Scribe used to
      # construct and fail later as a `NoMethodError` naming `nil` rather than
      # the construction site that handed it in.
      #
      # @param epic_slug [String] the epic every record this Scribe writes
      #   belongs to
      # @param journal [#<<] the open session Journal (or any object
      #   answering `#<<`)
      # @raise [Home::MalformedName] for a slug outside {Home::NAME}
      # @raise [ArgumentError] for a journal that cannot accept a record
      def initialize(epic_slug:, journal:)
        @epic_slug = Home.checked_name(epic_slug, "epic slug")
        @journal = refuse_unwritable!(journal)
        freeze
      end

      # @param stage [String, Stage] the stage beginning
      # @return [self]
      # @raise [UnknownStage] for a name outside {STAGES}
      def stage_started(stage) = write(StageTransition.new(epic_slug: @epic_slug, stage:, event: "started"))

      # @param stage [String, Stage] the stage finishing
      # @return [self]
      # @raise [UnknownStage] for a name outside {STAGES}
      def stage_completed(stage) = write(StageTransition.new(epic_slug: @epic_slug, stage:, event: "completed"))

      # @param id [String] the issue that moved
      # @param from [String] its prior status
      # @param to [String] its new status
      # @return [self]
      # @raise [ArgumentError] for a status outside {STORED_STATUSES}, on either side
      def issue_moved(id, from:, to:)
        write(IssueTransition.new(epic_slug: @epic_slug, issue_id: id, from_status: from, to_status: to))
      end

      # One structural edit, journaled with the payload that replays it. A
      # {Graph} carries no slug, so the fiber it yields carries none either --
      # naming the epic is why a graph cannot journal itself.
      #
      # @param fiber [GraphFiber] the revision a graph operation yielded
      # @return [self]
      # @raise [ArgumentError] for anything that is not one, before it reaches
      #   the journal -- a duck missing a member fails on the record's own
      #   keywords, naming the member it could not supply
      def graph_revised(fiber) = write(GraphRevision.new(epic_slug: @epic_slug, **fiber.to_h))

      private

      def refuse_unwritable!(journal)
        unless journal.respond_to?(:<<)
          raise ArgumentError, "journal must answer #<< (a Journal or an equivalent double), got #{journal.inspect}"
        end

        journal
      end

      def write(record)
        @journal << record
        self
      end
    end
  end
end
