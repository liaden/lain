# frozen_string_literal: true

module Lain
  # The diff-review surface: a changeset, the marks and notes a human leaves on
  # it, and the verdict that closes it.
  module Review
    # Every closed set the review surface judges a value against, in ONE place
    # and in ONE form.
    #
    # The form is Strings, and that is the whole point of them being here. The
    # journal is the durable artifact -- these values are what a record stores,
    # what NDJSON carries, and what a reader joins on a year later -- so the
    # String spelling is canonical and anything holding Symbols is a projection
    # of it. A second declaration in the Symbol form is worse than a duplicate:
    # the two sets are then not EQUAL, and `SIDES.include?(side)` answers false
    # for a perfectly valid value. Both ends coerce at their edges, so nothing
    # breaks on the day it is written; the pair itself is the trap.
    #
    # So a collaborator that wants Symbols derives them from here and a spec
    # pins the two spellings equal. Citing a vocabulary is also what lets a
    # record judge a `side` without depending on the object that owns anchors.
    #
    # They live in the NAMESPACE file because every guard that cites one
    # resolves it while its class body runs, and the namespace file is the one
    # thing guaranteed to be defined before anything beneath it, by how a
    # namespace is established at all.

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
    # shows once `Marks` folds its hunks' marks together. `reviewed`/`unreviewed`
    # are MARK_STATES' own spellings restated rather than computed with `+`,
    # because the order a legend reads best-to-worst in is not the order
    # MARK_STATES declares its pair in; `partial` is this set's own new member. A
    # spec pins these two against MARK_STATES rather than trusting the
    # restatement by eye.
    FILE_STATES = %w[reviewed partial unreviewed].freeze

    # What a diff says HAPPENED to a file, in the four spellings a TWO-TREE git
    # diff can produce. Here rather than inside `Source::ChangedFile` for
    # {SIDES}' reason: one declaration, with the Symbol form derived from it.
    #
    # NOT a wire vocabulary, and that correction is worth keeping because the
    # first version of this comment claimed it was. GitHub's files API spells
    # deletion `removed`, and also emits `copied`, `changed` and `unchanged` --
    # two of which a two-tree diff can never produce. So a GitHub-backed source
    # MAPS onto this one, and forcing the two equal would import spellings
    # nothing here can answer.
    #
    # Closed anyway: what a reader may be told about a file is a decision.
    # Distinct from the tri-state a MARK derives ({FILE_STATES}), which is not a
    # property of the diff at all.
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

    # Who let a round go without a verdict: a human's close, or a refusal raised
    # after the round's rails were bound. Kept apart because one is a decision
    # about the review and the other is a ceiling nobody chose.
    CLOSED_BY = %w[human refusal].freeze

    # The CLI's `--scope` used to be a sixth set here, `%w[commits cumulative]`.
    # It is {Partition::STRATEGIES} now, and the move is not tidying: a scope
    # names a GROUPING, the registry is where the groupings are, and a String
    # list beside it would be the second declaration the doc above calls worse
    # than a duplicate. It could not be derived here either -- these are the
    # namespace's own constants, established before `Partition` exists -- so the
    # registry IS the vocabulary, and everything wanting the String spelling
    # reads `strategy.name` off the port.
  end
end
