# frozen_string_literal: true

module Lain
  class TestLayout
    # What a `[tests]` table is allowed to SAY: the shape of each value, and
    # the words a refusal uses when one is wrong.
    #
    # Named and nested rather than left loose in {TestLayout}, because these
    # judge a RAW TOML value while the layout is what a well-shaped table
    # became -- the reader consults them once, at load, and nothing downstream
    # ever asks them anything. Keeping them a group also keeps this part a pure
    # namespace reopen, so the class's one docstring stays in `test_layout.rb`
    # where it belongs.
    module Shapes
      # A path the table names: relative, inside the project, and spelled one
      # way only, because a path is tested against it by prefix and `./app`
      # would silently miss everything under `app`. `-` is refused as a first
      # character because a level root reaches a test runner's command line,
      # where it would read as an option.
      module PathShape
        DOTS = %w[. ..].freeze

        module_function

        def canonical?(value)
          value.is_a?(String) && !value.empty? && !value.start_with?("/", "~", "-") &&
            value.split("/", -1).none? { |segment| segment.strip.empty? || DOTS.include?(segment) }
        end
      end

      # Two roots overlap when they are equal or one lies inside the other, so a
      # file under both would belong to each at once.
      module Overlap
        module_function

        def pair(paths) = paths.combination(2).find { |one, other| overlap?(one, other) }
        def overlap?(one, other) = one == other || one.start_with?("#{other}/") || other.start_with?("#{one}/")
      end

      # A refusal names the overlapping pair when that is what broke the rule,
      # since the shape alone would read as correct.
      module Clashing
        def describe(value)
          pair = clash(value)
          pair ? "#{self}; #{pair.join(" and ")} overlap" : to_s
        end
      end

      # Source roots may not overlap: a source under two of them would mirror to
      # two test paths, and the guard would pass one and refuse the other.
      Paths = Data.define(:minimum, :disjoint) do
        include Clashing

        def admits?(value) = shaped?(value) && !clash(value)

        def shaped?(value)
          value.is_a?(Array) && value.size >= minimum && value.all? { |path| PathShape.canonical?(path) }
        end

        def clash(value) = disjoint && shaped?(value) && Overlap.pair(value)

        def to_s = "a #{"non-empty " unless minimum.zero?}list of #{"distinct, non-nested " if disjoint}relative paths"
      end

      # Level roots may neither repeat nor nest: a file under two roots has two
      # levels, and no test path could satisfy both. `inline` is admitted only
      # for a preset whose levels do not mirror, since a mirrored test needs a
      # file of its own.
      Levels = Data.define(:inline) do
        include Clashing

        def admits?(value) = shaped?(value) && !clash(value)

        def shaped?(value) = value.is_a?(Hash) && !value.empty? && value.all? { |name, root| level?(name, root) }

        def level?(name, root)
          name.match?(/\A[a-z][a-z0-9_]*\z/) && (root == INLINE ? inline : PathShape.canonical?(root))
        end

        def clash(value) = shaped?(value) && Overlap.pair(value.values - [INLINE])

        def to_s
          "a table of lowercase level names to distinct, non-nested relative roots#{%( or "#{INLINE}") if inline}"
        end
      end

      OneOf = Data.define(:values) do
        def admits?(value) = values.include?(value)
        def describe(_value) = to_s
        def to_s = "one of #{values.join(", ")}"
      end

      # Only the two internal helpers are private here: the three RULES are
      # what {TestLayout.admit!} reaches for by name, and {PathShape} is the
      # sole authority on what a plain relative path inside the project looks
      # like -- the plan-declared subject a test is mirrored FROM has to be
      # judged by the same rule the `[tests]` source roots are, and two copies
      # of it meant tightening one left the other admitting what it now
      # refuses, with no spec anywhere failing.
      private_constant :Overlap, :Clashing
    end
  end
end
