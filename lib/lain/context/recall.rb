# frozen_string_literal: true

module Lain
  class Context
    # Recalls memory hits into the message tail: a pure function of a frozen
    # index snapshot and the message list. It is NOT part of the default
    # pipeline -- `Context.pipeline` is `Reminder >> CacheBreakpoints`, with no
    # memory index to search -- but an opt-in stage a custom pipeline composes
    # AFTER CacheBreakpoints (push-recall is a swept axis; the bench decides
    # whether it earns its tokens). Composed there, today's retrieval never
    # rewrites yesterday's cached prefix: the recall block rides the same
    # UNCACHED SUFFIX Reminder's workspace tail does, landing strictly after
    # the last neutral marker. `Request#prefix_digests` is block-granular
    # precisely so that displaced marker still computes rather than raising.
    #
    # Query extraction is a pinned rule, not a heuristic: take the text
    # blocks of the last user message, excluding <workspace>-tagged blocks
    # (Reminder's own injection) and tool_result blocks. After a tool turn
    # the last user message IS the tool_results, which are not a query, so
    # the search steps one user message further back at a time until it
    # finds real text -- or finds none, in which case nothing is injected.
    class Recall < Combinator
      include TailInjection

      # `k:` is the pinned constructor shape from the plan card (T10) --
      # top-k retrieval is exactly what it is elsewhere in the literature,
      # and a longer name would only paraphrase that.
      # rubocop:disable Naming/MethodParameterName
      def initialize(index:, k:)
        super()
        @index = index
        @k = Integer(k)
        # A non-positive k means "recall nothing", but `hits.first(@k)` would
        # only surface that at render time (first(0) is [], first(-1) raises).
        # Refuse it at construction, where the mistake was actually made.
        raise ArgumentError, "k must be positive, got #{@k}" unless @k.positive?

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

      # Walks user messages tail-first (lazily, so the walk stops the moment
      # real text is found): the last user message is the pinned primary
      # case, and falling further back only happens when it turns out to be
      # entirely tool_results or a bare workspace tail. The extraction rule
      # (real text minus <workspace> blocks) lives on {MessageEnvelope}; this
      # method owns only the tail-first walk. Changing the rule would move the
      # pinned bench-card behavior -- don't (see MessageEnvelope#workspace_tagged?).
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
