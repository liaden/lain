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

      # Two fixed spellings, with an approval's strict tail, so no note can be read as consent to network.
      NETWORK = /\A\s*(?:(?:approved|approve)\s+)?network(?:(?:#{GRAMMAR.dig(Verdict::Approve, :tail)})\s*\z|
                 (?:#{GRAMMAR.dig(Verdict::Approve, :separator)})(?<note>\S.*))/mix
      NETWORK_WORD = "network"

      # @param line [String]
      # @param network [Boolean] whether the asker offers the network answer; where it does not, as at an
      #   epic gate, that answer is unrecognised
      # @return [Verdict::Approve, Verdict::Hold, Verdict::Deny, Unrecognised]
      def self.parse(line, network: false)
        chosen = network && NETWORK.match(line.to_s)
        return Verdict::Approve.new(note: chosen[:note], network: true) if chosen

        kind, match = PATTERNS.lazy.map { |k, pattern| [k, pattern.match(line.to_s)] }.find { _2 }
        return Unrecognised.new(text: line.to_s.dup.freeze) unless match

        kind.new(note: match[:note])
      end

      # @param verdict [Verdict::Approve, Verdict::Hold, Verdict::Deny]
      # @return [String] the normal form {parse} reads back to an equal verdict, offering network for one that chose it
      def self.render(verdict)
        word = Verdict.coerce(verdict).network? ? NETWORK_WORD : WORDS.fetch(verdict.class).first
        verdict.note ? "#{word}, #{verdict.note}" : word
      end
    end
  end
end
