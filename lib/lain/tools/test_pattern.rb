# frozen_string_literal: true

module Lain
  module Tools
    # Runs an ast-grep pattern against a source snippet via
    # {Lain::Structural::Matcher#match} and reports the match count plus, per
    # match, its line and captures. This is the discovery half of the
    # ast-inspect pair: a pattern can parse cleanly and still UNDER-match --
    # `def $NAME($$$A)` finds a plain `def total(x)` but silently skips
    # `def self.x`, a distinct CST node -- and there is no exception to catch
    # for that, only a match count lower than the source warrants. Reporting
    # the count next to the actual per-match captures is what makes the gap
    # visible to the model reading it: a source with two method defs and a
    # report naming only one is the signal to reach for {AstDump} next and find
    # the node kind the pattern is missing.
    class TestPattern < Tool
      # The wire shape: the pattern under test, the source to run it against,
      # and which grammar to parse both with.
      class Input < Tool::Input
        field :pattern, :string, description: "An ast-grep pattern, e.g. \"def $NAME($$$A)\".",
                                 required: true
        field :code, :string, description: "The source snippet to match against.", required: true
        field :language, :string,
              description: "The language grammar to parse with, e.g. \"ruby\", \"python\", " \
                           "\"rust\", \"typescript\", \"javascript\".",
              required: true
      end

      input_model Input

      def name = "test_pattern"

      def description
        "Runs an ast-grep pattern against a source snippet and reports how " \
          "many structural matches it found, with the line and captures of " \
          "each. A valid pattern can still under-match a construct that looks " \
          "the same but parses to a different node kind (a singleton method " \
          "def vs a plain one, for example) -- if the count looks lower than " \
          "the source warrants, use ast_dump on the same snippet to see the " \
          "actual node kinds and adjust the pattern."
      end

      protected

      def perform(input, _invocation)
        matches = Structural::Matcher.new.match(source: input.code, language: language_of(input),
                                                pattern: input.pattern)
        Tool::Result.ok(report(matches))
      rescue Structural::Matcher::BadPattern, Structural::Matcher::UnknownLanguage => e
        Tool::Result.error(e.message)
      end

      private

      def language_of(input)
        input.language.downcase.to_sym
      end

      def report(matches)
        return "0 matches." if matches.empty?

        header = "#{matches.size} match#{"es" unless matches.size == 1}:"
        [header, *matches.each_with_index.map { |match, index| describe(match, index) }].join("\n")
      end

      def describe(match, index)
        "  #{index + 1}. line #{match.line}: #{captures_for(match)}"
      end

      def captures_for(match)
        return "(no captures)" if match.captures.empty?

        match.captures.map { |name, text| "#{name}=#{text.inspect}" }.join(", ")
      end
    end
  end
end
