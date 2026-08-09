# frozen_string_literal: true

module Lain
  module Review
    # Every closed set the review surface judges a value against, in ONE place
    # and in ONE form.
    #
    # The form is Strings, and that is the whole point of the file. The journal
    # is the durable artifact -- these values are what a record stores, what
    # NDJSON carries, and what a reader joins on a year later -- so the String
    # spelling is canonical and anything holding Symbols is a projection of it.
    # A second declaration in the Symbol form is worse than a duplicate: the two
    # sets are then not EQUAL, and `SIDES.include?(side)` answers false for a
    # perfectly valid value. Both ends coerce at their edges, so nothing breaks
    # on the day it is written; the pair itself is the trap.
    #
    # So a collaborator that wants Symbols derives them from here
    # (`SIDES.map(&:to_sym)`) rather than restating the members, and a spec pins
    # the two spellings equal. Citing a vocabulary is also what lets a record
    # judge a `side` without depending on the object that owns anchors: the
    # dependency is on the closed set, which cannot move, rather than on a
    # collaborator, which can.
    #
    # This file is required FIRST from the unit index, because every guard that
    # cites one of these resolves it while its class body runs.

    # Which side of a diff a position is on. Closed for {Epic::STAGE_EVENTS}'
    # reason: `side` is what tells an old-side anchor (a buffer materialized from
    # `git show <base>:<path>`) from a new-side one (the real file), and a third
    # spelling nobody expects would read as neither.
    SIDES = %w[old new].freeze

    # What a human can say about one hunk. Binary and closed, because the
    # tri-state a file or a commit shows is DERIVED from these rather than stored
    # beside them -- a `partial` here would be a second, coarser record of the
    # same fact, free to disagree with the derivation.
    MARK_STATES = %w[reviewed unreviewed].freeze

    # The derivation MARK_STATES' own doc anticipates: what a FILE (or a commit)
    # shows once T8 folds its hunks' marks together. `reviewed`/`unreviewed`
    # are MARK_STATES' own two spellings restated (not computed with `+`,
    # because the order a legend reads best-to-worst in is not the order
    # MARK_STATES declares its binary pair in); `partial` is this set's own new
    # member, for the case where some hunks are marked and some are not. A
    # SECOND, independent declaration of `reviewed`/`unreviewed` here would be
    # exactly the trap this file's own doc warns against (`Anchor::SIDES`'s
    # spec pins that pair equal for the same reason) -- so a spec pins these
    # two against MARK_STATES rather than trusting the restatement by eye
    # (`spec/lain/review/vocabulary_spec.rb`).
    FILE_STATES = %w[reviewed partial unreviewed].freeze

    # What a diff says HAPPENED to a file, in the four spellings a TWO-TREE git
    # diff can produce. Here rather than inside `Changeset::ChangedFile` for
    # {SIDES}' reason: one declaration, with the Symbol form derived from it
    # (`ChangedFile::STATUSES`) instead of restated beside it.
    #
    # NOT a wire vocabulary, and that correction is worth keeping because the
    # first version of this comment claimed it was. GitHub's files API spells
    # deletion `removed`, and also emits `copied`, `changed` and `unchanged` --
    # two of which a two-tree diff can never produce. The sets genuinely differ,
    # so a GitHub-backed source has to MAP onto this one, and forcing the two
    # equal would import spellings nothing here can answer while renaming one
    # every local reader already knows.
    #
    # Closed anyway: what a reader may be told about a file is a decision, so a
    # fifth spelling should be an edit here rather than a Symbol that quietly
    # starts appearing.
    #
    # Distinct from the tri-state a MARK derives ({FILE_STATES}), which is not a
    # property of the diff at all and is never a member of this set.
    FILE_STATUSES = %w[added deleted modified renamed].freeze

    # What a note claims to be. `blocker` is the one a verdict policy can read;
    # the other two are for the human and the agent reading afterwards.
    ANNOTATION_KINDS = %w[note question blocker].freeze

    # What a review can conclude. ONE member on purpose: the verdict vocabulary
    # is research open question 3 ("reuse the panel's APPROVE /
    # APPROVE-WITH-FIXES / REQUEST-CHANGES?") and is unsettled, and this chunk
    # journals only `approve`. Held as a closed set rather than left unvalidated
    # so that adding the second value is a deliberate edit HERE, with the
    # question settled, rather than a string that quietly starts appearing in
    # journals and sets the vocabulary by accident.
    VERDICTS = %w[approve].freeze

    # The CLI's `--scope` used to be a sixth set here, `%w[commits cumulative]`.
    # It is {Partition::STRATEGIES} now, and the move is not tidying: a scope
    # names a GROUPING, the registry is where the groupings are, and a String
    # list beside it would be the second declaration this file's own doc calls
    # worse than a duplicate -- free to disagree, with `SCOPES.include?(scope)`
    # answering false for a strategy that ships, registers and resolves.
    #
    # It could not be derived here either, which is the mechanical half of the
    # same point: this file loads FIRST, and a strategy needs `Partition` to
    # exist. So the registry is the vocabulary, and everything that wants the
    # String spelling reads `strategy.name` off the port.
  end
end
