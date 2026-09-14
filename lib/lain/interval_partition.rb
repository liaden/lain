# frozen_string_literal: true

module Lain
  IntervalPartition = Data.define(:owner, :span, :ranges)

  # Reopened rather than defined with a `Data.define ... do` block: a bare
  # constant or `class` keyword written inside that block is scoped to its lexical
  # position -- this file, i.e. `Lain` -- not to the Data-defined class.
  #
  # An ascending, non-overlapping list of ranges inside a span of message indices,
  # plus the seven conditions that make an answer one. It cannot be held in an
  # invalid state, so none of its three callers has to remember to check.
  #
  # It sits at lib level rather than inside {Compaction::Strategy} because only
  # one of those three callers is a strategy: a strategy's proposal, the runs a
  # set of cut points leaves, and the common refinement of two of those.
  #
  # A partition IS its span and its intervals. `owner` and `provenance` exist so a
  # refusal can name the strategy and the hook at fault -- a refusal citing a hook
  # nobody called sends a reader to a strategy that is not to blame -- and are
  # deliberately no part of identity, which is what lets the refinement meet state
  # its laws over partitions rather than over askers.
  class IntervalPartition
    # Named for what it is not: the conditions it enforces are well-formedness,
    # not style.
    class NotAPartition < Error; end

    OF = "IntervalPartition.of"
    COVERING = "IntervalPartition.covering"
    MEET = "IntervalPartition#meet"

    # @param span [Range] the indices the ranges must fall inside
    # @param ranges [Array<Range>] the proposal, as proposed
    # @param owner [String] the strategy or hook to name in a refusal --
    #   deliberately no part of identity (see "What a partition IS" above).
    # @param provenance [String] the constructor or hook a refusal names as
    #   what was asked, e.g. {OF} here or {Compaction::Strategy::Base}'s `HOOK`
    #   when a strategy calls through its own `#ranges`.
    def self.of(span, ranges, owner:, provenance: OF)
      new(owner:, span:, ranges:, provenance:)
    end

    # One range per contiguous run of indices the cut did not take: everything a
    # cut point separates stays separated, and the cut points fall in no range.
    #
    # @param span [Range] the whole span being partitioned; the cut points in
    #   `excluding` divide it into the runs left over.
    # @param excluding [#include?] the indices to cut at
    # @param owner [String] the strategy or hook to name in a refusal --
    #   deliberately no part of identity (see "What a partition IS" above).
    # @param provenance [String] the constructor or hook a refusal names as
    #   what was asked; defaults to {COVERING}, which is what a refusal names
    #   even when the caller reached it through a wrapper like
    #   {Compaction::Source::Derived}.
    def self.covering(span, excluding:, owner:, provenance: COVERING)
      of(span, runs(span, excluding, owner, provenance), owner:, provenance:)
    end

    # Both arguments are refused BY NAME because this constructor is published:
    # `nil.include?` raises a NoMethodError from inside the walk that names
    # nobody, and an endless span does not fail at all -- it enumerates forever.
    def self.runs(span, excluding, owner, provenance)
      refuse_unwalkable(span, owner, provenance)
      refuse_unaskable(excluding, owner, provenance)

      span.reject { |index| excluding.include?(index) }
          .chunk_while { |before, after| after == before + 1 }
          .map { |run| run.first..run.last }
    end

    def self.refuse_unwalkable(span, owner, provenance)
      return if span.is_a?(Range) && span.begin.is_a?(Integer) && span.end.is_a?(Integer)

      raise NotAPartition, "#{owner} asks #{provenance} for the runs of #{span.inspect}, which is not a " \
                           "bounded span of Integer indices"
    end

    def self.refuse_unaskable(excluding, owner, provenance)
      return if excluding.respond_to?(:include?)

      raise NotAPartition, "#{owner} asks #{provenance} to exclude #{excluding.inspect}, which cannot be " \
                           "asked whether it includes an index"
    end

    private_class_method :runs, :refuse_unwalkable, :refuse_unaskable

    Proposal = Data.define(:owner, :span, :ranges, :provenance)
    private_constant :Proposal

    # The answer AS PROPOSED. A separate object because a refusal has to quote
    # what the caller actually wrote while the partition holds the canonical
    # spelling: three of the seven checks speak about ranges that are perfectly
    # WELL FORMED, which is exactly the shape {IntervalPartition#canonical}
    # rewrites, so validating after normalization told an author about
    # `0..2 and 1..3` for a proposal that said `0...3, 1...4`.
    #
    # THE ORDER IS THE POINT. A non-collection cannot be asked for its elements at
    # all, a non-Range cannot be asked whether it is empty, and ranges out of order
    # would ALSO trip the overlap check -- so each refusal is stated on its own
    # terms, and a message names the fault a reader has to fix rather than
    # whichever later check happened to trip over it first.
    #
    # Reopened rather than written as a `Data.define ... do` block, this file's own
    # idiom one level up and for the same reason. It is also what
    # {Metrics/ClassLength} was reporting: a block body counts against the class
    # that lexically contains it, while a reopened one is measured as the separate
    # object the seven refusals already are.
    class Proposal
      def validated
        refuse_answerless
        refuse_foreign
        refuse_uncountable
        refuse_empty
        refuse_outside
        refuse_disorder
        refuse_overlap
        ranges
      end

      private

      # FIRST, because everything below asks a question only a collection can
      # answer. A strategy whose hook falls off the end answers `nil`, and
      # `nil.grep_v` named nobody -- a NoMethodError from inside the validator,
      # about the validator, for a bug in a strategy.
      def refuse_answerless
        return if ranges.is_a?(Array)

        raise NotAPartition, "#{owner} answers #{ranges.inspect} from #{provenance}; expected an " \
                             "Array of Ranges"
      end

      def refuse_foreign
        alien = ranges.grep_v(Range)
        return if alien.empty?

        raise NotAPartition, "#{owner} answers #{listed(alien)}, which is not a Range"
      end

      # A range's members ARE message indices, so a Range of anything but Integers
      # is a different type of thing, not a smaller kind of partition. `0.0..1.5`
      # cleared every check below it -- `cover?` compares numerically, and it is
      # neither empty nor out of order -- and died in the CALLER as `TypeError:
      # can't iterate from Float`, naming nobody. Unbounded ends are left to
      # #refuse_outside, which has something truer to say about them.
      def refuse_uncountable
        odd = ranges.select { |range| bounded?(range) && !integral?(range) }
        return if odd.empty?

        raise NotAPartition, "#{owner} answers #{listed(odd)}, whose endpoints are not Integer message " \
                             "indices"
      end

      def bounded?(range) = !range.begin.nil? && !range.end.nil?

      def integral?(range) = range.begin.is_a?(Integer) && range.end.is_a?(Integer)

      # An empty interval is no collapse at all, and answering one is how a
      # strategy would commit a replacement event that subsumes nothing. Refused
      # on its own terms rather than through #cover?, which reports `2..1` as
      # "outside 0..3" -- true of nothing, and it sends a reader hunting a bounds
      # bug.
      def refuse_empty
        hollow = ranges.select { |range| hollow?(range) }
        return if hollow.empty?

        raise NotAPartition, "#{owner} answers #{listed(hollow)}, an empty range; a range that " \
                             "collapses nothing is spelled by leaving it out"
      end

      def refuse_outside
        stray = ranges.reject { |range| span.cover?(range) }
        return if stray.empty?

        raise NotAPartition, "#{owner} answers #{listed(stray)}, outside the span it was asked " \
                             "about, #{span.inspect}"
      end

      def refuse_disorder
        pair = ranges.each_cons(2).find { |before, after| before.first > after.first }
        return if pair.nil?

        raise NotAPartition, "#{owner} answers #{pair.last.inspect} after #{pair.first.inspect}, " \
                             "so its ranges are not in ascending order"
      end

      def refuse_overlap
        pair = ranges.each_cons(2).find { |before, after| before.cover?(after.first) }
        return if pair.nil?

        raise NotAPartition, "#{owner} answers #{pair.first.inspect} and #{pair.last.inspect}, " \
                             "which overlap at #{pair.last.first}"
      end

      # An unbounded range is left to #refuse_outside, the check with something
      # true to say about it.
      def hollow?(range)
        return false if range.begin.nil? || range.end.nil?

        range.exclude_end? ? range.begin >= range.end : range.begin > range.end
      end

      def listed(ranges) = ranges.map(&:inspect).join(", ")
    end

    # Refused as proposed, then stored canonical. The owner is interned because an
    # anonymous class's `to_s` and every interpolation build a MUTABLE String, and
    # this value has to stay `Ractor.shareable?`.
    def initialize(owner:, span:, ranges:, provenance: OF)
      named = -owner.to_s
      Proposal.new(owner: named, span:, ranges:, provenance: -provenance.to_s).validated
      super(owner: named, span: canonical(span), ranges: canonicalized(ranges))
    end

    # Checked at construction; this names that fact and is not a second pass.
    def validated = ranges

    # `is_a?(IntervalPartition)` rather than `is_a?(self.class)`: identity here is
    # the span and the intervals, which a subclass changes neither of, so the
    # symmetric guard is the true one.
    def ==(other)
      other.is_a?(IntervalPartition) && span == other.span && ranges == other.ranges
    end
    alias eql? ==

    def hash = [IntervalPartition, span, ranges].hash

    # The common refinement of two partitions of one span: cut wherever EITHER
    # cuts, which for intervals is the pairwise intersection of their ranges.
    #
    # It covers only what BOTH cover, which is the half a set-partition reading
    # does not have: these partitions are partial (a gap is a stretch no range
    # claims, retained verbatim by the derivation), so a refinement that filled in
    # a gap because the other operand claimed it would be proposing a collapse
    # neither asker asked for.
    #
    # {Compaction::Strategy::Composed} is the caller and asks it backwards: two
    # strategies may be composed only when they claim disjoint stretches, which is
    # exactly "their meet is empty".
    #
    # It is the GREATEST lower bound under the refinement order {#refines?} names,
    # and its spec holds it to the four semilattice laws. Its partiality -- two
    # different spans refuse -- is {Dag::RenderAncestry.meet}'s with span
    # substituted for store.
    def meet(other)
      refuse_mismatched(other)
      IntervalPartition.new(owner: "#{owner} meet #{other.owner}", span:, ranges: intersections(other),
                            provenance: MEET)
    end

    # The order {#meet} is a meet OF, said as a predicate so "finer than each" is
    # a question a caller can ask rather than a claim only a comment makes.
    def refines?(coarser)
      span == coarser.span && ranges.all? { |mine| coarser.ranges.any? { |theirs| theirs.cover?(mine) } }
    end

    private

    def intersections(other)
      ranges.flat_map { |mine| other.ranges.filter_map { |theirs| shared(mine, theirs) } }
    end

    # Both operands are ascending and non-overlapping, so walking one against the
    # other in order yields the intersections in order too -- nothing to sort.
    #
    # A PLAIN Range, even when both operands were owner-tagged. #canonical goes to
    # some length to let a tagged range survive by identity; a refinement is the
    # opposite case, deliberately: an interval two strategies both claim has no
    # single owner, and finding exactly those is what the meet is for.
    def shared(one, another)
      first = [one.first, another.first].max
      last = [one.max, another.max].min

      first..last unless last < first
    end

    def refuse_mismatched(other)
      return if span == other.span

      raise NotAPartition, "#{owner} and #{other.owner} partition different spans, #{span.inspect} and " \
                           "#{other.span.inspect}; two spans have no common refinement"
    end

    # `0..2` and `0...3` are one interval with two spellings, normalized here so
    # equality and the refinement meet never see two names for one thing -- and
    # AFTER the refusals, so no message quotes a spelling its caller did not write.
    #
    # An already-inclusive range comes back BY IDENTITY rather than rebuilt, which
    # is what lets a Range SUBCLASS carrying its own data survive construction with
    # its class intact. An exclusive one is respelled as a plain Range: a subclass
    # carrying extra state cannot be assumed to accept `(begin, end)`, so a caller
    # needing its class kept proposes inclusively.
    def canonical(range)
      return range unless respellable?(range)

      range.begin..range.max
    end

    def canonicalized(ranges) = ranges.map { |range| canonical(range) }.freeze

    def respellable?(range)
      range.is_a?(Range) && range.exclude_end? &&
        range.begin.is_a?(Integer) && range.end.is_a?(Integer) && range.begin < range.end
    end
  end
end
