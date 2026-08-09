# frozen_string_literal: true

module Lain
  module Review
    class Partition
      # Do not group at all: one partition over every file, which is the flat
      # view a reader gets today at `scope: cumulative`.
      #
      # Degenerate by construction, and that is the point -- it is what makes
      # "the changeset whole" a member of the same axis as every other grouping
      # rather than the special case every dispatch table has to carry an
      # `else` for.
      class Whole
        # The vocabulary's own spelling of the flat view. The strategy is named
        # for what it DOES to the files (nothing) and the scope for what a
        # reader sees, which are two readings of one thing.
        NAME = "cumulative"

        # A partition still needs a label, whatever renders it. Deliberately NOT
        # `check_cumulative!`'s "the cumulative view": that guard reads
        # `view.files` directly and never sees a partition, so making the two
        # strings one would join a heading to a sentence nothing shares.
        LABEL = "the whole changeset"

        # `.freeze` by hand: the magic comment freezes only literals, and this
        # interpolates.
        ADVICE = "present it whole (scope: #{NAME}) instead".freeze

        # @return [String]
        def name = NAME

        # @return [String] what a refusal at another strategy recommends
        def advice = ADVICE

        # Every source can be shown whole, so there is none this declines.
        #
        # @return [true]
        def supports?(_source) = true

        # ALWAYS one partition, even over a changeset that touches nothing:
        # yielding none there would make "one group" a claim that holds only
        # sometimes, and a caller folding over the result would see the empty
        # changeset as an empty axis rather than as an empty group.
        #
        # @param changeset [#files]
        # @return [Array(Partition)]
        def partition(changeset) = [Partition.new(label: LABEL, files: changeset.files)]
      end
    end
  end
end
