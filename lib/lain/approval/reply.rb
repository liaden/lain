# frozen_string_literal: true

module Lain
  module Approval
    # The one grammar for a human's reply: a verdict word, then an optional
    # note. A word the grammar does not know is {Unrecognised}, never a deny,
    # so the caller asks again instead of guessing consent or refusal.
    module Reply
      Unrecognised = Data.define(:text)

      WORDS = {
        Verdict::Approve => %w[approved approve yes y],
        Verdict::Deny => %w[denied deny nope nah no n],
        Verdict::Hold => %w[hold wait stop]
      }.freeze

      # An approval is the one reading nobody may guess into, so it takes only a
      # full stop or exclamation marks as a tail and a note only after a comma,
      # colon or dash. A deny or hold may be looser: a stray reading costs less.
      # Punctuation separates a looser note only when space follows it or it
      # touches the word, so "n ./build" keeps its path.
      LOOSE = { tail: "[[:punct:]]*", separator: "[[:punct:]]\\s*|\\s+(?:[[:punct:]]\\s+)?" }.freeze

      GRAMMAR = {
        Verdict::Approve => { tail: "\\.?|!*|[,:\\-]\\s*", separator: "\\s*[,:\\-]\\s*" },
        Verdict::Deny => LOOSE,
        Verdict::Hold => LOOSE
      }.freeze

      PATTERNS = GRAMMAR.to_h do |kind, grammar|
        words = WORDS.fetch(kind).join("|")
        [kind, /\A\s*(?:#{words})(?:(?:#{grammar[:tail]})\s*\z|(?:#{grammar[:separator]})(?<note>\S.*))/mi]
      end.freeze

      # @param line [String]
      # @return [Verdict::Approve, Verdict::Hold, Verdict::Deny, Unrecognised]
      def self.parse(line)
        kind, match = PATTERNS.lazy.map { |k, pattern| [k, pattern.match(line.to_s)] }.find { _2 }
        return Unrecognised.new(text: line.to_s.dup.freeze) unless match

        kind.new(note: match[:note])
      end

      # @param verdict [Verdict::Approve, Verdict::Hold, Verdict::Deny]
      # @return [String] the normal form {parse} reads back to an equal verdict
      def self.render(verdict)
        word = WORDS.fetch(Verdict.coerce(verdict).class).first
        verdict.note ? "#{word}, #{verdict.note}" : word
      end
    end
  end
end
