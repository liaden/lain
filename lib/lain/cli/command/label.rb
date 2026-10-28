# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/label [digest] text`: name a committed turn in the session record,
      # for the human reading it back. Zero model turns.
      #
      # The leading word is a digest only when it has a digest's shape AND a
      # turn on the chain starts with it: `/label dead end` labels the head
      # "dead end", where `/label dead` clearing a turn would be a surprise.
      # Once it is taken as a digest, {Pin::Target} resolves it, so an ambiguous
      # prefix is refused exactly as `/pin` refuses it. Text left empty clears
      # the label.
      class Label
        DIGEST_SHAPE = /\A(?:blake3:\h*|\h{4,})\z/

        def initialize = freeze

        def name = "label"

        def usage = "/label [digest] text -- name a turn (default: the latest); no text clears the label"

        def call(args, env)
          timeline = env.timeline
          raise Pin::Refusal, "nothing to label: this session has no committed turns" if timeline.empty?

          digest, text = split(args.to_s.strip, timeline)
          env.agent.session.record_label(digest, text)
          reply(digest, text)
        end

        private

        def split(args, timeline)
          word, rest = args.split(/\s+/, 2)
          return [timeline.head_digest, args] unless names_a_turn?(word, timeline)

          [Pin::Target.new(timeline:, verb: name).resolve(word), rest.to_s.strip]
        end

        def names_a_turn?(word, timeline)
          return false unless word&.match?(DIGEST_SHAPE)

          bare = word.delete_prefix("blake3:")
          timeline.ancestor_digests.any? { |digest| digest.delete_prefix("blake3:").start_with?(bare) }
        end

        def reply(digest, text)
          shown = "#{Canonical.abbreviate(digest)}..."
          text.empty? ? "cleared the label on #{shown}" : "labeled #{shown}: #{text}"
        end
      end
    end
  end
end
