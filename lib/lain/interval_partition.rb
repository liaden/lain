# frozen_string_literal: true

module Lain
  IntervalPartition = Data.define(:owner, :span, :ranges)

  # Reopened rather than defined with a `Data.define ... do` block: a bare
  # constant or `class` keyword written inside that block is scoped to its
  # lexical position -- this file, i.e. `Lain` -- not to the Data-defined class
  # (the same trap {Request} states), and every refusal below names
  # {NotAPartition}.
  #
  # An interval partition of a span of message indices: an ascending,
  # non-overlapping list of ranges, all of them inside the span, and the seven
  # conditions that make an answer one. It cannot be held in an invalid state --
  # the conditions are checked at construction -- so no caller has to remember
  # to check, and there are three callers.
  #
  # It sits at lib level rather than inside {Compaction::Strategy} because those
  # three callers need it and only one of them is a strategy: a strategy's
  # proposal ({Compaction::Strategy::Base#ranges}), the runs a set of cut points
  # leaves ({Compaction::Source::Derived}'s pins), and the common refinement of
  # two of those. {ContentAddressed} is the precedent for a property that belongs
  # to the value rather than to its first caller.
  #
  # == What a partition IS, and what is only diagnosis
  #
  # A partition is its span and its intervals. `owner` -- and the `provenance`
  # the constructor consumes -- exist to make a refusal name the strategy and the
  # hook at fault, and are deliberately no part of identity: two partitions of
  # the same span into the same intervals ARE the same partition, whoever asked
  # for them. That is what lets the refinement meet state its laws over
  # partitions rather than over askers.
  #
  # == Provenance
  #
  # Where the ranges came from, supplied by whichever constructor was used.
  # {Compaction::Strategy::Base} names `#propose_ranges` because that is the hook
  # it called; a refusal reached through {.covering} names {.covering}. A refusal
  # citing a hook nobody called sends a reader to a strategy that is not at
  # fault.
  class IntervalPartition
    include Algebra::MeetSemilattice

    # An answer that is not an interval partition of the span it was asked
    # about. Loud, and named for what it is not: the conditions it enforces are
    # well-formedness, not style.
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

    # The partition a set of cut points leaves behind: one range per contiguous
    # run of indices the cut did not take. Everything a cut point separates stays
    # separated, and the cut points themselves fall in no range at all.
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

    # Its two arguments are refused BY NAME because this constructor is
    # published: `nil.include?` raises a NoMethodError from inside the walk that
    # names nobody -- the failure `#refuse_answerless` exists to abolish one
    # level up -- and an endless span does not fail at all, it enumerates
    # forever.
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

    # The answer AS PROPOSED, and the seven conditions that decide whether it
    # names a partition. A separate object because the two hold different things:
    # the partition holds the canonical spelling, and a refusal has to quote what
    # the caller actually wrote. Three of the seven -- #refuse_outside,
    # #refuse_disorder, #refuse_overlap -- speak about ranges that are perfectly
    # WELL FORMED, which is exactly the shape {IntervalPartition#canonical}
    # rewrites, so validating after normalization told an author about
    # `0..2 and 1..3` for a proposal that said `0...3, 1...4`, and named `0..3`
    # for the `0...4` span the derivation actually asks with.
    #
    # == The order is the point
    #
    # A non-collection cannot be asked for its elements at all, a non-Range
    # cannot be asked whether it is empty, and ranges out of order would ALSO
    # trip the overlap check -- so being told about an overlap when the real
    # fault is the ordering sends a reader to the wrong line. Each refusal is
    # stated on its own terms so that the message names the fault a reader has to
    # fix, rather than whichever later check happened to trip over it first.
    #
    # Reopened rather than written as a `Data.define ... do` block -- which is
    # this file's own idiom one level up, and for the same reason ({Request}'s
    # trap). It is also what {Metrics/ClassLength} was reporting: the seven
    # refusals are a second object's worth of code, and a block body counts
    # against the class that lexically contains it while a reopened one is
    # measured as the separate object it already is.
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

      # FIRST, because everything below asks the proposal a question only a
      # collection can answer. A strategy whose hook falls off the end (a guard
      # clause with no else, an `each` where a `map` was meant) answers `nil`,
      # and `nil.grep_v` named nobody -- a NoMethodError from inside the
      # validator, about the validator, for a bug in a strategy.
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

      # A range's members ARE message indices -- the caller maps them onto source
      # turns -- so a Range of anything but Integers is not a smaller kind of
      # partition, it is a different type of thing. `0.0..1.5` cleared every
      # check below it (`cover?` compares numerically, and it is neither empty
      # nor out of order) and died in the CALLER as `TypeError: can't iterate
      # from Float`, naming nobody. Unbounded ends are left to #refuse_outside,
      # which has something truer to say about them.
      def refuse_uncountable
        odd = ranges.select { |range| bounded?(range) && !integral?(range) }
        return if odd.empty?

        raise NotAPartition, "#{owner} answers #{listed(odd)}, whose endpoints are not Integer message " \
                             "indices"
      end

      def bounded?(range) = !range.begin.nil? && !range.end.nil?

      def integral?(range) = range.begin.is_a?(Integer) && range.end.is_a?(Integer)

      # An empty interval is not a small collapse, it is no collapse, and
      # answering one is how a strategy would commit a replacement event that
      # subsumes nothing. Refused on its own terms rather than through #cover?,
      # which reports `2..1` as "outside 0..3" -- true of nothing, and it sends
      # the reader looking for a bounds bug.
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

      # Bounded at both ends and covering nothing. An unbounded range is left to
      # #refuse_outside, which is the check that has something true to say about
      # it.
      def hollow?(range)
        return false if range.begin.nil? || range.end.nil?

        range.exclude_end? ? range.begin >= range.end : range.begin > range.end
      end

      def listed(ranges) = ranges.map(&:inspect).join(", ")
    end

    # Refused as proposed, then stored canonical. The owner is interned because
    # an anonymous class's `to_s` and every interpolation build a MUTABLE String
    # (CLAUDE.md's named trap) and this value has to stay `Ractor.shareable?`.
    def initialize(owner:, span:, ranges:, provenance: OF)
      named = -owner.to_s
      Proposal.new(owner: named, span:, ranges:, provenance: -provenance.to_s).validated
      super(owner: named, span: canonical(span), ranges: canonicalized(ranges))
    end

    # The ranges, and the name three call sites learned for asking. They were
    # checked at construction, so this says that what comes back has been
    # checked; it is not a second pass.
    def validated = ranges

    # ==/eql?/hash agree, per {ContentAddressed}'s convention, so a partition
    # dedupes in a Set and works as a Hash key. `is_a?(IntervalPartition)` rather
    # than `is_a?(self.class)`: identity here is the span and the intervals, and
    # a subclass would change neither, so the symmetric guard is the true one.
    def ==(other)
      other.is_a?(IntervalPartition) && span == other.span && ranges == other.ranges
    end
    alias eql? ==

    def hash = [IntervalPartition, span, ranges].hash

    # The common refinement of two partitions of one span: cut wherever EITHER
    # of them cuts, which for intervals is the pairwise intersection of their
    # ranges. So the result's cut points are the union of both sets, it is finer
    # than each, and meeting a partition with the trivial one -- the whole span,
    # uncut -- answers the other operand itself.
    #
    # It covers only what BOTH cover, and that is the half a set-partition
    # reading does not have: these partitions are partial (a gap is a stretch no
    # range claims, which the derivation retains verbatim), so a refinement that
    # filled in a gap because the other operand claimed it would be proposing a
    # collapse neither asker asked for.
    #
    # {Compaction::Strategy::Composed} is the caller, and it asks the question
    # backwards: two strategies may be composed only when they claim disjoint
    # stretches, which is exactly "their meet is empty".
    #
    # It is the GREATEST lower bound and not merely a lower bound, under the
    # refinement order {#refines?} names -- which is why it is declared a
    # semilattice at the foot of this class rather than described here. The
    # partiality (two different spans refuse) is {Timeline#meet}'s exactly:
    # that one is total relative to a store and raises {Store::CrossStore}
    # across stores, and {Algebra::MeetSemilattice}'s own doc calls a bottom
    # "relative to a store... a fact about the structure rather than a value
    # the structure holds". Substitute span for store and it is this class.
    def meet(other)
      refuse_mismatched(other)
      IntervalPartition.new(owner: "#{owner} meet #{other.owner}", span:, ranges: intersections(other),
                            provenance: MEET)
    end

    # Is every interval of this one inside an interval of `coarser`? The order
    # {#meet} is a meet OF, said as a predicate so that "finer than each" is a
    # question a caller can ask rather than a claim only this comment makes.
    def refines?(coarser)
      span == coarser.span && ranges.all? { |mine| coarser.ranges.any? { |theirs| theirs.cover?(mine) } }
    end

    private

    def intersections(other)
      ranges.flat_map { |mine| other.ranges.filter_map { |theirs| shared(mine, theirs) } }
    end

    # Both operands are ascending and non-overlapping, so walking one against
    # the other in order yields the intersections in order too -- there is
    # nothing to sort, and #refuse_disorder would say so if there were.
    #
    # A PLAIN Range, even when both operands were owner-tagged
    # ({Compaction::Strategy::Composed::Owned}). #canonical goes to some length
    # to let a tagged range survive #validated by identity; a refinement is the
    # opposite case, and deliberately: an interval two strategies both claim has
    # no single owner, and finding exactly those intervals is what the meet is
    # for.
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

    # `0..2` and `0...3` are one interval with two spellings, and both were paid
    # for: the `#max`-never-`#last` dance in {Compaction::Derivation} and the
    # exclusive-end arm of `#hollow?`. Normalized here so that equality and the
    # refinement meet never see two names for one thing -- and AFTER the
    # refusals, so no message ever quotes a spelling its caller did not write.
    #
    # An already-inclusive range comes back BY IDENTITY rather than rebuilt,
    # which is what lets a Range SUBCLASS carrying its own data survive
    # construction with its class intact. An exclusive one is respelled as a
    # plain Range: a subclass carrying extra state cannot be assumed to accept
    # `(begin, end)`, so a caller that needs its class kept proposes inclusively.
    def canonical(range)
      return range unless respellable?(range)

      range.begin..range.max
    end

    def canonicalized(ranges) = ranges.map { |range| canonical(range) }.freeze

    def respellable?(range)
      range.is_a?(Range) && range.exclude_end? &&
        range.begin.is_a?(Integer) && range.end.is_a?(Integer) && range.begin < range.end
    end

    # BELOW #meet, which it names. Prose and not a value, exactly as
    # {Timeline}'s two declarations are: the bottom that makes the meet total is
    # the partition claiming nothing, and there is no one of those to record --
    # a partition carries its span, so the bottom is a different value for every
    # span and is a fact about the structure rather than a member of it.
    meet_semilattice on: :meet, bottom: "the empty partition, per span"
  end
end
