# frozen_string_literal: true

module Lain
  module Friction
    # Diffs what an assistant said it did against the calls the Journal
    # recorded. A fixed phrase table, matched deterministically on the text of
    # assistant turns that issued no tool call (the closing statements); a claim
    # no successful call in the session backs is {Unbacked}. Mechanical floor
    # only: a model never judges here, so a paraphrase outside the table goes
    # unseen rather than guessed at.
    class Claims
      Unbacked = Data.define(:turn_digest, :claim, :reason)
      Claim = Data.define(:claim, :backed, :reason)
      private_constant :Claim

      # A claim needs a first-person subject right before its verb (or before
      # "... and <verb>"), so prose about someone else's work, or about commits
      # in general, never matches. A subject-less "Committed the fix." is a known
      # miss, as is any paraphrase outside this table.
      SUBJECT = /\b(?:I|we)(?:'ve|\s+have)?(?:\s+(?:just|also|then|now))?\s+/i
      LEAD = /(?:#{SUBJECT.source}|#{SUBJECT.source}(?:\S+\s+){1,4}?and\s+)/i
      TESTS = /#{SUBJECT.source}(?:ran|run)\s+(?:all\s+)?(?:the\s+|our\s+|my\s+)?(?:tests?|specs?|test\s+suite)\b/i
      TESTS_PASS = /\b(?:all\s+)?(?:the\s+)?tests\s+(?:pass|passed)\b/i
      COMMITTED = /#{LEAD.source}committed\b/i
      EDITED = %r{#{LEAD.source}(?:created|edited)\s+(?:the\s+|a\s+|new\s+){0,2}(?:file\s+)?`?([\w./-]+\.\w+)`?}i
      # A sentence that is a question, a condition or a future reports no finished work.
      HEDGED = /\b(?:if|once|unless|will|would|should|could|shall|want|let\sme|going\sto|only)\b|'ll|\?/i
      # Only the subject-less test claim needs this: a first-person claim is negated by
      # its verb not following the subject directly.
      NEGATED = /\b(?:not|never|nothing|none)\b|n't/i

      EDIT_TOOLS = %w[write_file edit_file].freeze
      RUNNER = Regexp.union(
        /\b(?:rspec|pytest|py\.test|jest|vitest|mocha|phpunit)\b/,
        /\b(?:cargo|go|rails)\s+test\b/, /\b(?:npm|yarn|pnpm)\s+(?:run\s+)?test\b/, /\bruby\s+-Itest\b/,
        /\brake(?:\s+(?:test|spec)\b|\s*(?:$|[;&|]))/, /\bmake\s+(?:test|check)\b/
      )
      GIT_COMMIT = /\bgit\b[^;&|\n]*\scommit\b/

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @param tool_call_index [Grader::ToolCallIndex]
      def initialize(entries, tool_call_index:)
        @entries = entries
        @calls = tool_call_index.reject { |call| call.is_error == true }
      end

      # @return [Array<Unbacked>]
      def unbacked
        stated.reject { |_digest, claim| claim.backed }
              .map { |digest, claim| Unbacked.new(turn_digest: digest, claim: claim.claim, reason: claim.reason) }
      end

      # @return [Integer] how many claims the phrase table found, backed or not
      def checked = stated.size

      private

      def stated
        @stated ||= closing_turns.flat_map do |record|
          claims(text_of(record)).map { |claim| [record.fetch("digest"), claim] }
        end
      end

      def closing_turns
        Journal.records(@entries).select { |record| closing?(record) }.to_a
      end

      def closing?(record)
        record["type"].to_s == "turn" && record["role"] == "assistant" &&
          blocks(record).none? { |block| block["type"] == "tool_use" }
      end

      def blocks(record)
        content = record["content"]
        content.is_a?(Array) ? content.grep(Hash) : []
      end

      def text_of(record)
        blocks(record).filter_map { |block| block["text"] if block["type"] == "text" }.join("\n")
      end

      def claims(text)
        sentences(text).flat_map { |sentence| test_claims(sentence) + commit_claims(sentence) + edit_claims(sentence) }
                       .uniq(&:claim)
      end

      def sentences(text)
        text.split(/(?<=[.!?])\s+|\n+/).grep_v(HEDGED)
      end

      def test_claims(text)
        label = test_label(text)
        return [] unless label

        [Claim.new(label, ran?("bash", RUNNER), "no test-runner call in the session")]
      end

      def test_label(text)
        return "ran the tests" if text.match?(TESTS)

        "tests pass" if text.match?(TESTS_PASS) && !text.match?(NEGATED)
      end

      def commit_claims(text)
        return [] unless text.match?(COMMITTED)

        [Claim.new("committed", ran?("bash", GIT_COMMIT), "no git commit call in the session")]
      end

      def edit_claims(text)
        text.scan(EDITED).flatten.uniq.map do |path|
          Claim.new("edited #{path}", edited?(path), "no write_file or edit_file call on #{path}")
        end
      end

      def edited?(path)
        @calls.any? { |call| EDIT_TOOLS.include?(call.name) && call.args["path"] == path }
      end

      def ran?(tool, pattern)
        @calls.any? { |call| call.name == tool && call.args["command"].to_s.match?(pattern) }
      end
    end
  end
end
