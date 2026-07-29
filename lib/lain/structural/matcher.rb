# frozen_string_literal: true

module Lain
  module Structural
    # The single Ruby seam over `Lain::Ext::AstGrep` (T1): no other unit may
    # reference that ext class directly, so a breaking ext bump touches this
    # file alone. It owns three things the ext deliberately does not: the
    # supported-language allowlist (rejecting a typo BEFORE the FFI call),
    # byte -> 1-based line conversion (the ext hands back byte offsets and its
    # own 0-based line as a convenience, per ext/lain/src/astgrep.rs -- the
    # pinned contract is the byte range, and turning that into a line number a
    # human reads is wrapper work), and insulating callers from the ext's own
    # `BadPattern` class by re-raising a wrapper-owned one.
    #
    # Stateless like the ext it wraps (see astgrep.rs's module doc): no index
    # handle, nothing cached between calls, so #initialize only freezes self --
    # matching Memory::Bm25's shape minus the build step Bm25 needs and this
    # does not.
    class Matcher
      # A pattern that does not parse to a valid syntax node. Rescued from
      # `Ext::AstGrep::BadPattern` so a caller (and every spec) can rescue
      # ONE class rooted at Lain::Error without knowing the ext exists.
      class BadPattern < Error; end

      # A language outside the seeded set. Named in the message, per the
      # project's loud-failure convention -- never a silent nil or an
      # unguarded ext ArgumentError leaking a foreign vocabulary.
      class UnknownLanguage < Error; end

      # The ext refused to dump: the source nests past its depth cap, which is a
      # stack bound with no safe prefix to return (a 4 KB deeply nested source
      # dumped to 12 MB and overflowed the walk's stack before it existed). The
      # message names the cap.
      #
      # The ext RAISES THIS CLASS DIRECTLY, looked up by name at raise time --
      # the shape `Lain::Canonical`'s errors already have, where the Rust side
      # of a capability raises the Ruby unit's own vocabulary. It is deliberately
      # not a re-raise: mapping it here meant rescuing a Ruby builtin
      # (`RangeError`), which caught unrelated failures out of the same call and
      # reported them to the model as a cap that had not been hit.
      #
      # Running past the ext's OUTPUT cap is not this: that truncates the dump
      # and discloses it inline, mirroring {Tools::AstSearch}'s "capped at N".
      class DumpCapped < Error; end

      # ast-grep-core's own supported set is larger; this project's seam only
      # vouches for the languages it actually exercises (T2's catalog is
      # Ruby-only so far). Extend as a language grows real callers.
      SUPPORTED_LANGUAGES = %i[ruby rust python typescript javascript].freeze

      # One structural match: a 1-based source line, the byte range of the
      # whole matched node, and named single-node captures (metavar name =>
      # captured text). Deeply frozen -- Data instances freeze themselves, the
      # Range is frozen by Ruby's own Range invariant, and #build_captures
      # freezes the Hash it builds.
      Match = Data.define(:line, :byte_range, :captures)

      def initialize
        freeze
      end

      # @param source [String]
      # @param language [Symbol]
      # @param pattern [String] an ast-grep pattern, e.g. "def $NAME($$$A)"
      # @return [Array<Match>] in source order; [] for a valid pattern with no
      #   matches.
      # @raise [BadPattern] the pattern does not parse to a valid syntax node.
      # @raise [UnknownLanguage] +language+ is outside {SUPPORTED_LANGUAGES}.
      def match(source:, language:, pattern:)
        lang = checked_language(language)
        raw_matches = Ext::AstGrep.search(source, lang, pattern)
        lines = LineIndex.new(source)
        raw_matches.map { |raw| build_match(lines, raw) }
      rescue Ext::AstGrep::BadPattern => e
        raise BadPattern, e.message
      end

      # @param source [String]
      # @param language [Symbol]
      # @return [String] the CST node kinds, newline-delimited and indented --
      #   how an agent sees that `def self.x` is a `singleton_method`, distinct
      #   from the `method` node its `def $NAME` pattern actually matches. A
      #   dump past the ext's output cap ends with a `... capped at N bytes`
      #   line rather than being refused.
      # @raise [UnknownLanguage] +language+ is outside {SUPPORTED_LANGUAGES}.
      # @raise [DumpCapped] the source nests past the ext's depth cap. Raised BY
      #   the ext as this class (see {DumpCapped}), so there is nothing to map
      #   here and no builtin to rescue.
      def dump(source:, language:)
        Ext::AstGrep.dump(source, checked_language(language))
      end

      private

      def checked_language(language)
        unless SUPPORTED_LANGUAGES.include?(language)
          raise UnknownLanguage, "unknown language #{language.inspect}, expected one of " \
                                 "#{SUPPORTED_LANGUAGES.inspect}"
        end

        language.to_s
      end

      def build_match(lines, raw)
        Match.new(line: lines.line_at(raw.fetch("start")), byte_range: raw.fetch("start")...raw.fetch("end"),
                  captures: captures_for(raw.fetch("captures")))
      end

      def captures_for(raw_captures)
        raw_captures.transform_values { |capture| capture.fetch("text") }.freeze
      end

      # Byte offset -> 1-based line, for ONE source. The line number is computed
      # here rather than trusted from the ext's own 0-based `line`, because byte
      # offsets are the pinned contract (see the ext's module doc) and the line
      # a human reads is wrapper work.
      #
      # It is an object because the derivation needs state the wrapper method
      # cannot hold: the newline offsets, built ONCE per source and binary
      # searched, so N matches cost O(bytes + N log lines) instead of the
      # O(N x bytes) that counting newlines in a per-match byte prefix cost.
      # Lazily, at that -- {Tools::AstSearch} calls {Matcher#match} once per
      # pattern per file and most files match nothing, so an eager scan would
      # spend on every file what the old derivation spent only on the ones that
      # matched.
      class LineIndex
        def initialize(source)
          @source = source
        end

        # The number of newlines strictly BEFORE +byte+, plus one -- byte for
        # byte the answer `source.byteslice(0, byte).b.count("\n") + 1` gives.
        def line_at(byte)
          (offsets.bsearch_index { |offset| offset >= byte } || offsets.size) + 1
        end

        private

        # The byte offset of every "\n". `.b` for the reason the byte-prefix
        # count carried it: a newline is one ASCII byte whatever the string's
        # encoding tag claims, so this cannot raise "invalid byte sequence" on a
        # source whose tag lies. Only the LAST line can lack its "\n", so the
        # `end_with?` guard drops that one non-offset and nothing else, and each
        # offset is its predecessor plus the line's own bytes.
        #
        # The separator is passed EXPLICITLY: bare `each_line` honours `$/`, and
        # the `count("\n")` this replaced did not, so a caller that had set `$/`
        # would silently re-number every match.
        def offsets
          @offsets ||= @source.b.each_line("\n").with_object([]) do |line, found|
            found << ((found.last || -1) + line.bytesize) if line.end_with?("\n")
          end
        end
      end
      private_constant :LineIndex
    end
  end
end
