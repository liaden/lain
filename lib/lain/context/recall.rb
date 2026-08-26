# frozen_string_literal: true

module Lain
  class Context
    # Recalls memory hits into the message tail: a pure function of a frozen
    # index snapshot and the message list. NOT part of the default pipeline but
    # an opt-in stage a custom pipeline composes AFTER CacheBreakpoints, so
    # today's retrieval never rewrites yesterday's cached prefix -- the recall
    # block rides the same UNCACHED SUFFIX Reminder's workspace tail does.
    # `Request#prefix_digests` is block-granular precisely so that displaced
    # marker still computes rather than raising.
    #
    # Query extraction is a pinned rule, not a heuristic: the text blocks of the
    # last user message, excluding <workspace>-tagged blocks and tool_result
    # blocks. After a tool turn the last user message IS the tool_results, which
    # are not a query, so the search steps one user message further back at a
    # time until it finds real text -- or finds none and injects nothing.
    class Recall < Combinator
      include TailInjection
      include Declarative

      # A non-positive k means "recall nothing", but `hits.first(@k)` would only
      # surface that at render time (first(0) is [], first(-1) raises). Refuse it
      # at construction, where the mistake was actually made.
      declare do
        attribute :k
        validates :k, numericality: { greater_than: 0, message: "must be positive, got %<value>s" }
      end

      # `k:` is top-k retrieval's name everywhere else in the literature; a
      # longer one would only paraphrase it.
      # rubocop:disable Naming/MethodParameterName
      def initialize(index:, k:)
        super()
        @index = index
        # Checked on the COERCED value, where the guard clause it replaces
        # checked it: `Integer(k)` is what refuses a non-number, and the sign
        # rule only means anything once that has passed.
        @k = Integer(k)
        self.class.check!(k: @k)

        freeze
      end
      # rubocop:enable Naming/MethodParameterName

      def call(messages)
        return messages if messages.empty?
        return messages unless MessageEnvelope.wrap(messages.last).user?

        query = derive_query(messages)
        return messages if query.nil?

        hits = @index.search(query).first(@k)
        return messages if hits.empty?

        append_to_last(messages, [recall_block(hits)])
      end

      private

      # Lazily, so the walk stops the moment real text is found. Falling
      # further back than the last user message only happens when it turns out
      # to be entirely tool_results or a bare workspace tail. The extraction
      # RULE lives on {MessageEnvelope}; this method owns only the walk.
      def derive_query(messages)
        messages.reverse_each.lazy
                .map { |message| MessageEnvelope.wrap(message) }
                .select(&:user?)
                .filter_map(&:query_text)
                .first
      end

      def recall_block(hits)
        lines = hits.map { |hit| "#{hit.id} | #{hit.description} -- #{hit.why}" }
        { "type" => "text", "text" => "<recall>\n#{lines.join("\n")}\n</recall>" }
      end
    end
  end
end
