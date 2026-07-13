# frozen_string_literal: true

require_relative "base"
require_relative "../workspace"

module Lain
  class Context
    # Recalls memory hits into the message tail: a pure function of a frozen
    # index snapshot and the message list. Ordered AFTER CacheBreakpoints in
    # the pipeline (context.rb) so today's retrieval never rewrites
    # yesterday's cached prefix -- the recall block rides the same UNCACHED
    # SUFFIX Reminder's workspace tail does, landing strictly after the last
    # neutral marker.
    #
    # Query extraction is a pinned rule, not a heuristic: take the text
    # blocks of the last user message, excluding <workspace>-tagged blocks
    # (Reminder's own injection) and tool_result blocks. After a tool turn
    # the last user message IS the tool_results, which are not a query, so
    # the search steps one user message further back at a time until it
    # finds real text -- or finds none, in which case nothing is injected.
    class Recall < Base
      # `k:` is the pinned constructor shape from the plan card (T10) --
      # top-k retrieval is exactly what it is elsewhere in the literature,
      # and a longer name would only paraphrase that.
      # rubocop:disable Naming/MethodParameterName
      def initialize(index:, k:)
        super()
        @index = index
        @k = Integer(k)
        freeze
      end
      # rubocop:enable Naming/MethodParameterName

      def call(messages)
        return messages if messages.empty?

        last = messages.last
        return messages unless last["role"] == "user"

        query = derive_query(messages)
        return messages if query.nil?

        hits = @index.search(query).first(@k)
        return messages if hits.empty?

        rest = messages[0..-2]
        rest + [{ "role" => last["role"], "content" => last["content"] + [recall_block(hits)] }]
      end

      # Plain text injection -- no Provider capability is needed.
      def requires
        [].freeze
      end

      private

      # Walks user messages tail-first (lazily, so the walk stops the moment
      # real text is found): the last user message is the pinned primary
      # case, and falling further back only happens when it turns out to be
      # entirely tool_results or a bare workspace tail.
      def derive_query(messages)
        messages.reverse_each.lazy
                .select { |message| message["role"] == "user" }
                .filter_map { |message| query_text(message) }
                .first
      end

      def query_text(message)
        texts = real_text_blocks(message).map { |block| block["text"] }
        texts.join("\n") unless texts.empty?
      end

      def real_text_blocks(message)
        message["content"].select { |block| block["type"] == "text" && !workspace_tagged?(block) }
      end

      # Provenance is inferred from string content: genuine user text that
      # literally starts with the tag is excluded too. Inherited from the
      # card's pinned extraction rule -- an accepted tradeoff, since blocks
      # carry no provenance field to ask instead.
      def workspace_tagged?(block)
        block["text"].to_s.start_with?(Workspace::OPENING_TAG)
      end

      def recall_block(hits)
        lines = hits.map { |hit| "#{hit.id} | #{hit.description} -- #{hit.why}" }
        { "type" => "text", "text" => "<recall>\n#{lines.join("\n")}\n</recall>" }
      end
    end
  end
end
