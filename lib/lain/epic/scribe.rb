# frozen_string_literal: true

module Lain
  module Epic
    # The epic tier's one write path. {IssueTransition} and {StageTransition}
    # already refuse a bad shape at construction (see {Guards} in records.rb),
    # so a Scribe is thin on purpose: it names the epic once, builds the
    # record, and hands it to the Journal. That thinness is the point --
    # nothing else in lib constructs either record (`scribe_write_side_spec.rb`
    # pins it), so the write-side guard is checked in exactly one place.
    #
    # {Progress.fold} re-checks the same {Guards} on the way back in, but it is
    # NOT the only other place a shape gets judged, and this comment used to
    # say so. The fold also judges two things the write side structurally
    # cannot: graph membership (`Lineage`, raising {UnknownIssue} for an id no
    # live issue holds) and byte-exact slug equality (`Refold#mine?`, raising
    # {ForeignJournal}). The second of those is why {Home.checked_name} is run
    # here too -- see below.
    #
    # A raised Guard error happens before `@journal <<` runs -- both records'
    # `#initialize` validate before `Data`'s own `super` freezes the value --
    # so a refused transition never reaches the journal at all.
    class Scribe
      # `epic_slug` is passed through {Home.checked_name}, not merely
      # presence-checked. `Guards::IssueTransition`/`Guards::StageTransition`
      # only demand a non-blank string, but `Refold#mine?` partitions
      # journaled records on byte-exact equality against the slug a caller
      # names to {Progress.fold} -- and that slug always came from a real
      # {Home}, which refuses anything {Home.checked_name} would refuse. A
      # Scribe built on " demo", "Demo", or "the-plan " would pass the
      # transition's own guard, write happily, and then partition as SOMEONE
      # ELSE'S epic: `mine?` drops it as foreign rather than the record's own
      # guard refusing it, so the transition simply never folds in -- silently,
      # in an append-only file, with no exception UNLESS every other record in
      # the journal happens to share the same bad slug (in which case the
      # journal-level {ForeignJournal} check fires, backwards from what an
      # author would expect: loud in the trivial case, silent in the
      # realistic one). Checking here, once, at the one place a slug is named,
      # is the only point that can catch it before it is unrecoverably wrong.
      #
      # This is a real, deliberate behavior change from this card's first
      # pass: a slug that used to construct silently (any non-blank string)
      # now raises {Home::MalformedName} unless it already matches
      # {Home::NAME} -- lowercase letters, digits and dashes, opening with a
      # letter or a digit. Every slug reaching a REAL epic already satisfies
      # this (it came from {Home.resolve}), so no legitimate caller is
      # affected; a caller passing a raw, unvalidated string is exactly the
      # caller this exists to stop.
      #
      # `journal` is checked too, for {Progress}'s own reason
      # (`named_epic`/`refuse_stranger!`, "this constructor is public, so it
      # says so instead of hoping"): a Scribe built on `journal: nil`
      # constructed successfully and only failed on the first write, deep
      # inside the private `#write` method, as a `NoMethodError` naming `nil`
      # rather than the construction site that handed it in.
      #
      # @param epic_slug [String] the epic every record this Scribe writes
      #   belongs to
      # @raise [Home::MalformedName] for a slug outside {Home::NAME}
      # @param journal [#<<] the open session Journal (or any object
      #   answering `#<<`)
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
