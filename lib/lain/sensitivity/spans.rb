# frozen_string_literal: true

module Lain
  class Sensitivity
    Spans = Data.define(:list)

    # Reopened rather than defined with a `Data.define ... do` block: a constant
    # written inside that block is scoped to the enclosing module.
    #
    # An ascending list of separated byte spans: the one shape {Masking.render}
    # walks. Built only through {of}, so a list nothing detected cannot reach the
    # walk unchecked. Region metadata stays out; it is not commutative and a
    # union must be.
    class Spans
      include Enumerable

      # A negative offset would index from the end of the content.
      class NegativeSpan < Error; end

      # Rendering such a list would emit masked bytes raw.
      class OutOfOrder < Error; end

      Span = Data.define(:start, :length)

      # Byte offsets, because {Masking} walks content as bytes.
      class Span
        def finish = start + length

        def reaches?(other) = other.start <= finish

        def covers?(other) = start <= other.start && other.finish <= finish
      end

      # @param spans [Enumerable<#start, #length>]
      # @return [Spans] sorted, with any overlap or touch merged
      def self.of(spans)
        new(list: merged(spans.map { checked(_1) }.sort_by(&:start)).freeze)
      end

      # @return [Spans] the bytes either covers
      def self.union(left, right) = of(left.list + right.list)

      # For a list that claims to be ascending already: refuses a span that begins
      # before the previous one ends instead of sorting it into place.
      def self.ascending(spans)
        spans.each_cons(2) do |before, after|
          if after.start < before.start + before.length
            raise OutOfOrder,
                  "span at start #{after.start} begins before the one ending at #{before.start + before.length}"
          end
        end
        of(spans)
      end

      def self.checked(span)
        if span.start.negative? || span.length.negative?
          raise NegativeSpan,
                "span with start #{span.start} and length #{span.length}"
        end

        Span.new(start: span.start, length: span.length)
      end

      def self.merged(sorted)
        sorted.inject([]) do |kept, span|
          kept.last&.reaches?(span) ? [*kept[..-2], widened(kept.last, span)] : [*kept, span]
        end
      end

      def self.widened(span, other) = Span.new(start: span.start, length: [span.finish, other.finish].max - span.start)

      private_class_method :new, :checked, :merged, :widened

      def each(&block) = list.each(&block)

      def covers?(other) = other.all? { |part| list.any? { _1.covers?(part) } }

      EMPTY = of([])
    end
  end
end
