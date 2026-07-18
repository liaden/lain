# frozen_string_literal: true

module Lain
  module Structural
    # The loader for lain's OWN hand-authored, role-tagged tree-sitter query
    # files (`queries/<lang>/symbols.scm`), read from disk at call time. Where
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

      # The languages lain ships an authored symbols query for. Python is
      # deferred (a follow-up), so it is intentionally absent -- fetch(:python)
      # must raise, not guess.
      SUPPORTED_LANGUAGES = %i[ruby typescript rust].freeze

      module_function

      # The raw tree-sitter query source for +language+'s symbols, read from the
      # authored `queries/<language>/symbols.scm`.
      #
      # @param language [Symbol]
      # @return [String] the `.scm` query source, ready for Ext::TreeSitter.query
      # @raise [Unsupported] +language+ has no authored query (names the value).
      def fetch(language)
        unless SUPPORTED_LANGUAGES.include?(language)
          raise Unsupported, "unsupported language #{language.inspect}, expected one of " \
                             "#{SUPPORTED_LANGUAGES.inspect} (python is deferred)"
        end

        File.read(path_for(language))
      end

      # The on-disk location of +language+'s authored query, resolved relative to
      # this file so it works from any working directory.
      def path_for(language)
        File.join(__dir__, "queries", language.to_s, "symbols.scm")
      end
    end
  end
end
