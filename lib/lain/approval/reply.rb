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

      # Two fixed spellings each, with an approval's strict tail, so no note can be read as consent to network or
      # to secrets.
      CHOSEN = %w[network secrets].to_h do |word|
        [word.to_sym, /\A\s*(?:(?:approved|approve)\s+)?#{word}(?:(?:#{GRAMMAR.dig(Verdict::Approve, :tail)})\s*\z|
                       (?:#{GRAMMAR.dig(Verdict::Approve, :separator)})(?<note>\S.*))/mix]
      end.freeze
      NETWORK_WORD = "network"
      SECRETS_WORD = "secrets"
      # An approval that names both words asks for what no answer gives, so it is asked again.
      BOTH = [/\bnetwork\b/i, /\bsecrets\b/i].freeze

      # @param line [String]
      # @param network [Boolean] whether the asker offers the network answer; where it does not, as at an
      #   epic gate, that answer is unrecognised
      # @param secrets [Boolean] whether the asker offers the secrets answer, likewise
      # @return [Verdict::Approve, Verdict::Hold, Verdict::Deny, Unrecognised]
      def self.parse(line, network: false, secrets: false)
        text = line.to_s
        verdict = chosen(text, network:, secrets:) || plain(text)
        return Unrecognised.new(text: text.dup.freeze) if verdict.nil? || ((network || secrets) && both?(verdict, text))

        verdict
      end

      # @param verdict [Verdict::Approve, Verdict::Hold, Verdict::Deny]
      # @param line [String] the line it was read from
      # @return [Boolean] whether it approves on a line that names both network and secrets
      def self.both?(verdict, line) = verdict.approved? && BOTH.all? { line.match?(_1) }

      # @param verdict [Verdict::Approve, Verdict::Hold, Verdict::Deny]
      # @return [String] the normal form {parse} reads back to an equal verdict, offering the answer it chose
      def self.render(verdict)
        word = if Verdict.coerce(verdict).network? then NETWORK_WORD
               elsif verdict.secrets? then SECRETS_WORD
               else WORDS.fetch(verdict.class).first
               end
        verdict.note ? "#{word}, #{verdict.note}" : word
      end

      def self.chosen(text, network:, secrets:)
        { network:, secrets: }.select { _2 }.lazy.filter_map do |answer, _|
          CHOSEN.fetch(answer).match(text)&.then { Verdict::Approve.new(note: _1[:note], answer => true) }
        end.first
      end

      def self.plain(text)
        kind, match = PATTERNS.lazy.map { |k, pattern| [k, pattern.match(text)] }.find { _2 }
        kind&.new(note: match[:note])
      end
      private_class_method :chosen, :plain
    end
  end
end
