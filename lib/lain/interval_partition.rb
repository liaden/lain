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
    # An answer that is not an interval partition of the span it was asked
    # about. Loud, and named for what it is not: the conditions it enforces are
    # well-formedness, not style.
    class NotAPartition < Error; end

    OF = "IntervalPartition.of"
    COVERING = "IntervalPartition.covering"

    # @param span [Range] the indices the ranges must fall inside
    # @param ranges [Array<Range>] the proposal, as proposed
    def self.of(span, ranges, owner:, provenance: OF)
      new(owner:, span:, ranges:, provenance:)
    end

    # The partition a set of cut points leaves behind: one range per contiguous
    # run of indices the cut did not take. Everything a cut point separates stays
    # separated, and the cut points themselves fall in no range at all.
    #
    # @param excluding [#include?] the indices to cut at
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
    Proposal = Data.define(:owner, :span, :ranges, :provenance) do
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
    private_constant :Proposal

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

    private

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
  end
end
