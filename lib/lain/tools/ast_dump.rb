# frozen_string_literal: true

module Lain
  module Tools
    # Dumps a source snippet's concrete syntax tree, node kind by node kind, via
    # {Lain::Structural::Matcher#dump}. This is the diagnostic half of the
    # ast-inspect pair: {TestPattern} shows a model that a pattern under-matched
    # (e.g. `def $NAME($$$A)` silently skipping `def self.x`); this tool is how
    # the model finds the REAL node kind it needs (`singleton_method`) to fix
    # the pattern, rather than guessing at syntax.
    class AstDump < Tool
      # The wire shape: a code snippet plus which grammar to parse it with.
      class Input < Tool::Input
        field :code, :string, description: "The source snippet to parse.", required: true
        field :language, :string,
              description: "The language grammar to parse with, e.g. \"ruby\", \"python\", " \
                           "\"rust\", \"typescript\", \"javascript\".",
              required: true
      end

      input_model Input

      def name = "ast_dump"

      def description
        "Dumps the concrete syntax tree of a source snippet, one node kind per " \
          "line, indented by nesting. Use this to discover the exact node kind " \
          "an ast-grep pattern needs -- especially after test_pattern reports " \
          "fewer matches than expected, which usually means a construct you " \
          "assumed shared a node kind (e.g. a singleton method def) actually " \
          "parses to a different one."
      end

      protected

      def perform(input, _invocation)
        dumped = Structural::Matcher.new.dump(source: input.code, language: language_of(input))
        Tool::Result.ok(dumped)
      rescue Structural::Matcher::UnknownLanguage => e
        Tool::Result.error(e.message)
      end

      private

      def language_of(input)
        input.language.downcase.to_sym
      end
    end
  end
end
