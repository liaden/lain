# frozen_string_literal: true

module Lain
  module Survey
    module Chunker
      Paragraphs = Data.define(:ceiling)

      # The universal floor: a file split at its blank lines, with the runs
      # packed toward the ceiling. It needs no grammar, no language and no
      # syntax tree, which is exactly why every other chunker falls back to it
      # -- an oversized markdown leaf, a setext-authored document, a language
      # with no authored query, a file whose bytes are not valid UTF-8 -- and
      # why it is the one that authors the coverage contract.
      #
      # A paragraph here is a run of lines up to AND INCLUDING the blank lines
      # that follow it. Attaching the blanks upward rather than downward is what
      # makes the split gap-free without a separate whitespace unit: a blank
      # line is content the file holds, and a unit of nothing but blank lines is
      # a mark a reviewer cannot read.
      #
      # Runs are then packed, not emitted one per paragraph, because a mark per
      # sentence is as useless as a mark per file. A single paragraph larger
      # than the ceiling is emitted WHOLE and over-ceiling rather than cut:
      # cutting hands a reviewer half a thought and makes the other half a
      # separate mark, and the ceiling is a target, not a promise.
      #
      # It takes no {Granularity}, and that is measured rather than assumed:
      # packing toward a ceiling already bounds granularity from the other side,
      # and over this repository's 619 `lib/**/*.rb` files it produces no file
      # above one unit per five lines. The chunkers that read STRUCTURE are the
      # ones that need a minimum imposed.
      class Paragraphs
        def initialize(ceiling: DEFAULT_CEILING) = super(ceiling: Integer(ceiling))

        # @param path [String] the path the units will carry
        # @param source [String] the whole file
        # @return [Array<Unit>] ordered, covering every line exactly once
        def call(path:, source:) = pack(path:, lines: Unit.lines_of(source), start_line: 1, label: "")

        # The same split over a SLICE, for the chunkers that fall back to this
        # one: they own the label and the line the slice starts at, and this
        # owns how it divides.
        #
        # @param path [String]
        # @param lines [Array<String>] terminator-free, as {Unit.lines_of} gives them
        # @param start_line [Integer] 1-based line the slice starts at
        # @param label [String] the structure the slice was found inside
        # @return [Array<Unit>]
        def pack(path:, lines:, start_line:, label:)
          runs = packed(paragraphs(lines))
          starts = runs.inject([start_line]) { |lead, run| lead << (lead.last + run.size) }
          runs.zip(starts).map { |run, line| Unit.new(path:, label:, start_line: line, lines: run) }
        end

        private

        # A new paragraph opens where a blank line is followed by a non-blank
        # one -- the only boundary in a file with no structure to read.
        def paragraphs(lines)
          lines.slice_when { |before, after| blank?(before) && !blank?(after) }.to_a
        end

        # `strip` and not `empty?`: a CRLF file's blank line is "\r", which is a
        # line separator wearing content's clothes. `.b` because the line may
        # hold bytes that are not valid UTF-8, and `strip` on those raises --
        # the same reason {Review::Hunk#body} works a line at a time.
        def blank?(line) = line.b.strip.empty?

        # Greedy, and greedy is right here: a run already over the ceiling
        # accepts nothing more, so an unsplittable paragraph never drags a
        # neighbour over with it.
        def packed(paragraphs)
          paragraphs.each_with_object([]) do |paragraph, runs|
            if runs.empty? || (runs.last.size + paragraph.size > ceiling)
              runs << paragraph.dup
            else
              runs.last.concat(paragraph)
            end
          end
        end
      end
    end
  end
end
