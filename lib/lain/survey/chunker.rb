# frozen_string_literal: true

module Lain
  module Survey
    # The chunkers: how a file becomes an ordered list of {Unit}s, and the one
    # law all of them answer to.
    #
    # == The coverage contract
    #
    # Units are ordered, and every line of the file belongs to exactly ONE of
    # them -- stated as a reconstruction (`spec/support/shared_examples/
    # survey_chunker.rb`), never as a line count, because a count is satisfied
    # by a chunking that duplicates one line and drops another. A line in no
    # unit is never shown to a reviewer, so marking the file reviewed would be a
    # lie; this is `Bounds`' own never-truncate discipline one tier down.
    #
    # Every chunker here is a strategy over the same two messages -- `#call`
    # for a whole file, and the floor's `#pack` for a slice one of the others
    # could not split structurally. {Paragraphs} is the floor and is injected
    # into the others rather than reached for, which is why an oversized
    # markdown leaf and an unrecognised language produce the same honest answer.
    #
    # Each is a frozen `Data` rather than a lambda or a plain object, so two
    # chunkers built the same way are EQUAL. That matters downstream, not here:
    # a chunker reaches `MarkedChangeset`'s row table, which is keyed under a
    # no-default `fetch`, and a callable that compares unequal after a rebuild
    # raises a `KeyError` a long way from its cause.
    module Chunker
      # Lines, not bytes: a unit is read by a human, and a line count is what a
      # reviewer's attention actually spends. Sized so a unit fits a screen --
      # this repo's own H2 markdown sections run into the hundreds of lines, so
      # a ceiling far above that would make adaptive depth decorative.
      DEFAULT_CEILING = 60

      # The other end of the same question: a unit smaller than this is not
      # worth a mark, so {Granularity} merges it into its neighbour. Chosen from
      # the measurement rather than from taste -- see that class, and the note
      # on why five is the smallest value that holds the bound.
      DEFAULT_MINIMUM = 5

      # What the structural chunkers can actually hand to a parser, which is
      # NOT the question `valid_encoding?` answers. Measured against the ext:
      # it refuses on the encoding TAG as well as on the bytes, so an
      # ISO-8859-1-tagged String raises `source must be UTF-8, got ISO-8859-1`
      # even when every byte in it is ASCII. These three tags are accepted and
      # every other named encoding is refused outright.
      PARSEABLE_ENCODINGS = [Encoding::UTF_8, Encoding::US_ASCII, Encoding::BINARY].freeze

      module_function

      # Whether {Ext::TreeSitter} will read this source, asked BEFORE handing it
      # over so its offset-naming EncodingError never escapes a chunker. A
      # source that fails goes to the paragraph floor: a survey that drops a
      # stray latin-1 file is worse than one that reads it as prose.
      def parseable?(source)
        PARSEABLE_ENCODINGS.include?(source.encoding) && utf8_bytes?(source)
      end

      # The bytes must decode as UTF-8 whatever the tag says -- a binary-tagged
      # String is always `valid_encoding?` and still refused if its bytes are
      # not UTF-8. The `ascii_only?` arm is there to skip the copy in the common
      # case rather than to widen what is accepted.
      def utf8_bytes?(source)
        return source.valid_encoding? if source.encoding == Encoding::UTF_8

        source.ascii_only? || source.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end
    end
  end
end

# The floor FIRST: it is the default collaborator of every chunker below, named
# in their default arguments, as is `granularity`.
require_relative "chunker/paragraphs"
require_relative "chunker/granularity"
require_relative "chunker/markdown"
