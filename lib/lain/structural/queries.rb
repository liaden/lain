# frozen_string_literal: true

module Lain
  module Structural
    # The loader for lain's OWN hand-authored, role-tagged tree-sitter query
    # files (`queries/<lang>/<query>.scm`), read from disk at call time. Where
    # Structural::Patterns is the ast-grep *metavariable* catalog, this owns the
    # raw tree-sitter S-expression queries Ext::TreeSitter runs -- each authored
    # so a capture binds the identifier node DIRECTLY to a role
    # (`@definition.method`, `@reference.call`), because Ext::TreeSitter returns
    # FLAT captures with no per-match grouping to correlate a separate @name.
    #
    # The `.scm` files are MIT original work (node patterns referenced from the
    # pinned tree-sitter grammars' own MIT queries), NOT vendored Apache-2.0
    # locals.scm -- deliberately, to avoid a NOTICE obligation.
    #
    # Reading at call time rather than caching keeps this a pure function of the
    # on-disk file: the queries are hand-iterated artifacts, edited far more
    # often than a session reads them, and a per-call file read is nothing next
    # to parsing the source the query then runs against.
    module Queries
      # A language with no authored query file. Named in the message, per the
      # project's loud-failure convention -- python is deliberately DEFERRED, so
      # it lands here rather than silently returning nothing.
      class Unsupported < Error; end

      # A SUPPORTED language whose authored `.scm` is somehow absent -- a
      # packaging bug, not a user error. Raised (naming the query file) rather
      # than letting a bare `Errno::ENOENT` be misattributed downstream as a
      # failure to read the user's OWN source file.
      class Missing < Error; end

      # Which queries lain ships for which language -- the gate, and it is a
      # TABLE rather than a language list because the two axes are independent.
      # markdown ships `sections` and no `symbols`; ruby, typescript and rust
      # ship `symbols` and no `sections`. A flat allowlist could only say
      # "markdown is supported", which would turn Tools::FileSymbols' honest
      # user error over a markdown file into a Missing -- a packaging bug it
      # would be reporting against a file that is not missing at all. Python is
      # deferred (a follow-up), so it is intentionally absent from every row.
      QUERIES = {
        ruby: %i[symbols].freeze,
        typescript: %i[symbols].freeze,
        rust: %i[symbols].freeze,
        markdown: %i[sections].freeze
      }.freeze

      module_function

      # The raw tree-sitter query source for one of +language+'s authored
      # queries, read from `queries/<language>/<query_name>.scm`.
      #
      # @param language [Symbol]
      # @param query_name [Symbol] `:symbols`, `:sections`
      # @return [String] the `.scm` query source, ready for Ext::TreeSitter.query
      # @raise [Unsupported] no such query is authored for +language+ (names both).
      # @raise [Missing] the authored file is absent -- a packaging bug.
      def fetch(language, query_name)
        authored = QUERIES.fetch(language, [])
        raise Unsupported, refusal(language, query_name, authored) unless authored.include?(query_name)

        path = path_for(language, query_name)
        raise Missing, "authored query file missing: #{path}" unless File.exist?(path)

        File.read(path)
      end

      # The languages shipping +query_name+ -- what a refusal offers instead,
      # so asking python for symbols is never answered with markdown. Also the
      # single answer to "can lain parse this?", asked by every caller rather
      # than restated in a second table.
      def languages_for(query_name)
        QUERIES.select { |_language, names| names.include?(query_name) }.keys
      end

      # Two refusals, because the actionable fact differs. For an unknown
      # LANGUAGE, it is which languages ship the query that was asked for. For a
      # known one, it is what that language does ship -- "expected one of []",
      # which is what offering the other languages' query names would print,
      # tells the reader nothing at all.
      def refusal(language, query_name, authored)
        return "language #{language.inspect} ships #{authored.inspect}, not #{query_name.inspect}" if authored.any?

        "no authored #{query_name} query for language #{language.inspect}, " \
          "expected one of #{languages_for(query_name).inspect}"
      end

      # The on-disk location of an authored query, resolved relative to this
      # file so it works from any working directory.
      def path_for(language, query_name)
        File.join(__dir__, "queries", language.to_s, "#{query_name}.scm")
      end
    end
  end
end
