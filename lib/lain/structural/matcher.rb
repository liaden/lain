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
        raw_matches.map { |raw| build_match(source, raw) }
      rescue Ext::AstGrep::BadPattern => e
        raise BadPattern, e.message
      end

      # @param source [String]
      # @param language [Symbol]
      # @return [String] the CST node kinds, newline-delimited and indented --
      #   how an agent sees that `def self.x` is a `singleton_method`, distinct
      #   from the `method` node its `def $NAME` pattern actually matches.
      # @raise [UnknownLanguage] +language+ is outside {SUPPORTED_LANGUAGES}.
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

      def build_match(source, raw)
        Match.new(line: line_for(source, raw.fetch("start")), byte_range: raw.fetch("start")...raw.fetch("end"),
                  captures: captures_for(raw.fetch("captures")))
      end

      # 1-based line, computed here rather than trusted from the ext's own
      # 0-based `line` -- counting newlines in the byte prefix is the pinned
      # contract (byte offsets only); `.b` sidesteps a spurious "invalid byte
      # sequence" if a boundary ever lands mid multi-byte character, since a
      # newline is a single ASCII byte regardless of the string's encoding tag.
      def line_for(source, start_byte)
        source.byteslice(0, start_byte).b.count("\n") + 1
      end

      def captures_for(raw_captures)
        raw_captures.transform_values { |capture| capture.fetch("text") }.freeze
      end
    end
  end
end
