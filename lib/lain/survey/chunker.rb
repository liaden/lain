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

      # The extensions {Markdown} claims. A README picks one of these three
      # arbitrarily and none of them says anything different about the content,
      # so all three route the same way. Everything this list does not name
      # takes the floor, which is an honest answer rather than a degraded one --
      # widening it further is a decision somebody makes rather than one that
      # leaks in.
      MARKDOWN = %w[.md .markdown .mdown].freeze

      module_function

      # Which chunker a path gets.
      #
      # The dispatch is a NAMED function rather than a case statement inside the
      # corpus, because it is the seam a caller substitutes: `Source::Corpus`
      # takes it as `chunker:` and defaults to this, which is how a survey's
      # laziness is observable at all -- a counting chunker pushed through here
      # rides the real stack instead of spying on one.
      #
      # Structure first, floor last. Markdown goes to its section tree; a
      # language lain has an authored symbols query for goes to its definitions;
      # everything else -- an unknown extension, a language whose query was
      # withdrawn, a `Makefile` -- goes to {Paragraphs}. The floor is never a
      # failure: a survey that cannot read a `.lua` file at all is worse than
      # one that reads it as prose.
      #
      # A fresh instance per call, and that costs nothing that matters: a
      # chunker is a frozen `Data`, so two built the same way are EQUAL, which
      # is exactly the property {Review::LazyFile}'s equality needs of whatever
      # chunks a file.
      #
      # @param path [String, Pathname] the file's path; only its extension is read
      # @return [#call] a chunker, answering `call(path:, source:)`
      def for(path)
        extension = File.extname(path.to_s)
        return Markdown.new if MARKDOWN.include?(extension)
        return Code.new if parsed_language?(extension)

        Paragraphs.new
      end

      # {Structural::Queries} is the one classifier and is asked here rather
      # than trusted to {Code}'s own fallback: a language whose authored query
      # is withdrawn must take the floor by the dispatch's decision, so the
      # routing a reader can see is the routing that happens.
      def parsed_language?(extension)
        language = Code::EXTENSIONS[extension]

        !language.nil? && Structural::Queries.languages_for(:symbols).include?(language.name)
      end

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
require_relative "chunker/code"
