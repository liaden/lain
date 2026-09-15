# frozen_string_literal: true

module Lain
  module Tools
    # Runs an ast-grep pattern against a source snippet and reports the match
    # count plus each match's line and captures. The discovery half of the
    # ast-inspect pair: a pattern can parse cleanly and still UNDER-match --
    # `def $NAME($$$A)` finds `def total(x)` but silently skips `def self.x`, a
    # distinct CST node -- and there is no exception to catch for that, only a
    # count lower than the source warrants. Reporting the count beside the
    # per-match captures is what makes the gap visible, and the signal to reach
    # for {AstDump}.
    class TestPattern < Tool
      # An ENUMERATION under {Tool::Bounds}' boundary, taking {Grep}'s and
      # {AstSearch}'s 200 outright rather than inventing a second number for the
      # same shape.
      #
      # `report`'s header states the TRUE count, so the two numbers are
      # deliberately allowed to disagree: the header is what the pattern found,
      # the rows are what fits.
      BOUND = Tool::Bounds::Enumeration.new(limit: 200, unit: "matches")

      # A capture is as long as the snippet the model sent, so the rows also
      # meet a byte ceiling.
      BYTE_BOUND = Tool::Bounds::Fill.new(limit: Tool::Bounds::CEILINGS.fetch("test_pattern"), unit: "matches",
                                          narrower: ["test a smaller snippet"])

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
          "each. The count is always the true one; the per-match rows are " \
          "capped at #{BOUND.limit} and a capped report says so. " \
          "A valid pattern can still under-match a construct that looks " \
          "the same but parses to a different node kind (a singleton method " \
          "def vs a plain one, for example) -- if the count looks lower than " \
          "the source warrants, use ast_dump on the same snippet to see the " \
          "actual node kinds and adjust the pattern."
      end

      # Audited: matches the given `code` String in-memory via a fresh,
      # per-call Structural::Matcher, documented stateless. No filesystem, no
      # Session, no process-global state.
      def parallel_safe? = true

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
        rows = matches.first(BOUND.limit).each_with_index.map { |match, index| describe(match, index) }
        trailers = BOUND.admits?(matches.size) ? [] : [BOUND.notice(matches.size)]
        [header, *BYTE_BOUND.fit(rows, beside: [header, *trailers]), *trailers].join("\n")
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
