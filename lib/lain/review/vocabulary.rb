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
  end
end
