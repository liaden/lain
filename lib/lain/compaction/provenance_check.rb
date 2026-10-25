# frozen_string_literal: true

module Lain
  module Compaction
    # A {Strategy::Base} decorator: the inner strategy's ranges and claims, and its blocks with each
    # sentence about what the user said or approved marked unverified unless the user's own turns in
    # that range bear it out. A summarizer repeating a tool's "the user approved this" would otherwise
    # hand the model a fabricated approval in the human's voice.
    class ProvenanceCheck < Strategy::Base
      GRANTS = "said|says|asked|approved?|approval|wants|wanted|confirmed|confirmation|agreed|agreement|told|" \
               "requested|" \
               "authori[sz]ed|authori[sz]ation|okayed|consented?|allowed|permitted|permission|accepted|" \
               "signed\\ off|green-?lit|go-ahead|said\\ yes"
      ACTOR = /\b(the\ )?(user|human)\b/i
      CLAIM = /#{ACTOR}[^.!?]{0,40}?\b(#{GRANTS})\b|\b(#{GRANTS})\b[^.!?]{0,40}?\bby\ (the\ )?(user|human)\b/i
      CLAIM_WORDS = %w[user human user's human's said says asked approved approve approval wants wanted confirmed
                       confirmation agreed agreement told requested authorised authorized authorisation authorization
                       okayed consented consent allowed permitted permission accepted signed off green lit greenlit
                       go ahead yes].freeze

      # Function words only: a content word dropped here would let a claim ride on filler overlap.
      STOP = Set.new(%w[a an the and or but of to in on at by for with from as is are was were be been it its this that
                        these those he she they them his her their i you we me my your our not no so if then than
                        too very can could will would should shall may might do does did has have had there here
                        what which who whom when where why how all any some each into out up down over under again
                        also just about after before]).freeze

      # Looser passes paraphrase and fabrication alike, stricter demotes honest rewording; 0.6 is the trade.
      SUPPORT = 0.6

      DEMOTION = "(unverified: not in the user's own words) "

      SENTENCE = /(\s*)(\S(?:"[^"]*"|\u201C[^\u201D]*\u201D|.)*?(?:[.!?]+(?=\s|\z)|\z))/m
      QUOTED = /"([^"]+)"|\u201C([^\u201D]+)\u201D/
      private_constant :CLAIM_WORDS, :SENTENCE, :QUOTED

      # @param inner [Strategy::Base] the strategy whose summaries are checked
      # @param journal [#<<] where a {Telemetry::ClaimDemoted} lands for each collapse that demoted a sentence not
      #   journaled before: a re-derived range demotes the same sentence again
      def initialize(inner:, journal: Channel::Null.instance)
        super()
        @inner = inner
        @journal = journal
        @journaled = Set.new
      end

      def name = @inner.name

      def hits = @inner.hits

      def misses = @inner.misses

      def size_declined_misses = @inner.size_declined_misses

      def propose_ranges(messages, span:) = @inner.propose_ranges(messages, span:)

      def propose_claims(messages, span:) = @inner.propose_claims(messages, span:)

      def blocks(messages) = checked(@inner.blocks(messages), messages)

      def blocks_for(messages, range) = checked(@inner.collapse(messages, range:).content, messages)

      private

      def checked(blocks, messages)
        turns = human_turns(messages)
        demoted = []
        result = blocks.map do |block|
          block["text"].is_a?(String) ? block.merge("text" => vetted(block["text"], turns, demoted)) : block
        end
        journal_new(demoted)
        result
      end

      def journal_new(demoted)
        fresh = demoted.select { |sentence| @journaled.add?(Canonical.digest([name, sentence])) }
        @journal << Telemetry::ClaimDemoted.new(strategy: name, count: fresh.size) unless fresh.empty?
      end

      def vetted(text, turns, demoted)
        text.gsub(SENTENCE) { marked(Regexp.last_match(1), Regexp.last_match(2), turns, demoted) }
      end

      def marked(lead, sentence, turns, demoted)
        return "#{lead}#{sentence}" if supported?(sentence, turns)

        demoted << sentence
        "#{lead}#{DEMOTION}#{sentence}"
      end

      def supported?(sentence, turns)
        return true unless CLAIM.match?(sentence)

        quotes_present?(sentence, turns) && overlaps?(sentence, turns)
      end

      def quotes_present?(sentence, turns)
        folded = turns.map { |turn| fold(turn) }
        sentence.scan(QUOTED).flatten.compact.all? { |quote| folded.any? { |turn| turn.include?(fold(quote)) } }
      end

      def overlaps?(sentence, turns)
        claim = tokens(sentence) - CLAIM_WORDS
        return false if claim.empty?

        turns.any? { |turn| (claim & tokens(turn)).size.fdiv(claim.size) >= SUPPORT }
      end

      def human_turns(messages)
        messages.filter_map { |message| human_text(message) }
      end

      def human_text(message)
        envelope = Context::MessageEnvelope.wrap(message)
        return unless envelope.user?

        texts = envelope.real_text_blocks.reject { |block| Recap.block?(block) }.map { |block| block["text"] }
        texts.join("\n") unless texts.empty?
      end

      def tokens(text) = text.downcase.scan(/\w+(?:['\u2019]\w+)*/).reject { |word| STOP.include?(word) }.uniq

      def fold(text) = text.downcase.gsub(/\s+/, " ").strip
    end
  end
end
