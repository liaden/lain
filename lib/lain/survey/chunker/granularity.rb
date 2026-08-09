# frozen_string_literal: true

module Lain
  module Survey
    module Chunker
      Granularity = Data.define(:minimum)

      # A unit has to be worth a mark. This merges consecutive units that are
      # too small to be one, and it is the MIRROR of {Paragraphs}' packing --
      # the same greedy walk over consecutive groups, bounded from below
      # instead of above.
      #
      # It exists because a structural chunker splits where the STRUCTURE says,
      # and structure does not care how much text it encloses. Measured over
      # this repository's 619 `lib/**/*.rb` files, the code chunker put 49 of
      # them above one unit per five lines and 23 exactly on it, because every
      # nesting level captures as a definition: `module Lain` / `module Review`
      # / `class Hunk` is three one-line units before the file has said
      # anything. `version.rb` -- five lines -- came out as three units.
      #
      # Merging is the only repair that keeps the coverage contract: adjacent
      # units are concatenated in place, never dropped and never reordered, and
      # the merged unit starts where the first one did. Adjacency is asserted
      # rather than assumed, because a chunker that reordered its units would
      # otherwise be silently rewritten into one that did not.
      #
      # The trailing runt merges BACKWARD, which is what makes the guarantee
      # total: every emitted unit then holds at least `minimum` lines unless the
      # whole file holds fewer, so a chunking can never exceed one unit per
      # `minimum` lines. Without it a file of `n * minimum + 1` lines ends on a
      # one-line unit and the bound is off by one exactly where the AC measures.
      #
      # == What coarser marking costs, stated because it is real
      #
      # A {Unit}'s content key is position-independent, so an edit ABOVE a unit
      # does not move its key. Merging is positional, though: which units join
      # which run depends on where every boundary above them fell. So one line
      # inserted at the top of a file can re-draw every merge below it, and each
      # re-drawn unit's content -- and therefore its key -- changes with it.
      #
      # Measured over this repository, one line inserted at the top: `session.rb`
      # loses 1 mark of 21 and `finding.rb` 2 of 14, which is the ordinary case.
      # `cli/command/sessions.rb` loses **4 of 4** -- a small file whose units
      # are all merges loses everything, where the same file un-merged loses 1
      # of 9. A file short enough to coalesce into ONE unit loses its only mark
      # to any edit at all.
      #
      # That is the price of a mark being worth something, and it is paid where
      # marks are cheapest to re-earn -- but it is a price, not a free win, and
      # `code_spec.rb` pins it so it cannot drift in silence.
      class Granularity
        def initialize(minimum: DEFAULT_MINIMUM) = super(minimum: Integer(minimum))

        # @param units [Array<Unit>] ordered and gap-free
        # @return [Array<Unit>] ordered and gap-free, each at least `minimum`
        #   lines unless it is the only one
        def coalesce(units)
          absorb_runt(units.each_with_object([]) do |unit, runs|
            if runs.empty? || runs.last.lines.size >= minimum
              runs << unit
            else
              runs[-1] = joined(runs.last, unit)
            end
          end)
        end

        private

        def absorb_runt(runs)
          return runs if runs.size < 2 || runs.last.lines.size >= minimum

          runs[0..-3] + [joined(runs[-2], runs[-1])]
        end

        def joined(first, second)
          unless second.start_line == first.end_line + 1
            raise ArgumentError, "cannot coalesce non-adjacent units: #{first.end_line} then #{second.start_line}"
          end

          Unit.new(path: first.path, label: label_for(first, second),
                   start_line: first.start_line, lines: first.lines + second.lines)
        end

        # Both labels, in order, because a merged unit really does hold both
        # and naming only the first would make the label a half-truth a reviewer
        # cannot check. Repeats collapse -- a section split by the floor gives
        # every piece the same label.
        def label_for(first, second)
          [first.label, second.label].reject(&:empty?).uniq.join(", ")
        end
      end
    end
  end
end
