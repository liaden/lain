# frozen_string_literal: true

module Lain
  module Review
    class Partition
      # Group a changeset's files by the directory that holds them.
      #
      # It reads `File.dirname` off a path and NOTHING else -- no walk, no
      # numstat, no second question to the source -- which is what makes it the
      # strategy that proves the axis is real: a port whose only implementation
      # is {Whole} is degenerate by construction and proves nothing, and this one
      # is testable against an ordinary branch changeset today.
      #
      # The repository root is spelled `.`, which is `File.dirname`'s own answer
      # and git's. Naming it anything friendlier would be a second spelling of a
      # directory nobody would then be able to grep for.
      class ByDirectory
        NAME = "by_directory"

        # `.freeze` by hand, {Whole::ADVICE}'s reason: this interpolates.
        ADVICE = "present it per directory (scope: #{NAME}) instead".freeze

        # @return [String]
        def name = NAME

        # @return [String] what a refusal at another strategy recommends
        def advice = ADVICE

        # A path is all this reads, and every source answers a diff, so there is
        # none it declines.
        #
        # @return [true]
        def supports?(_source) = true

        # `group_by` keeps first-encounter order, so the partitions come back in
        # the diff's own directory order and a re-render cannot reshuffle the
        # view. Every file lands in exactly one group, which is the conservation
        # law the whole axis rests on.
        #
        # @param changeset [#files]
        # @return [Array<Partition>] one per distinct directory, in the order the
        #   diff first reached each
        def partition(changeset)
          changeset.files
                   .group_by { |file| File.dirname(file.path) }
                   .map { |directory, files| Partition.new(label: directory, files:) }
        end
      end
    end
  end
end
