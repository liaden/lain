# frozen_string_literal: true

module Lain
  module Memory
    # A Manifest::Hit-duck search index backed by Lain::Ext::Bm25 (the `bm25`
    # crate, in-process -- see T8 and ext/lain/src/bm25.rs). Where Manifest is
    # the always-runs lexical floor, Bm25 is a boosting arm over the SAME
    # corpus: it never replaces Manifest as the pointer layer, it only ranks
    # (references/memory-and-retrieval.md #2).
    #
    # Built ONCE from an index snapshot's items (id, description + body) --
    # the crate's data-structure placement rules cross the FFI boundary in one
    # batch, never per query (see ext/lain/CLAUDE.md rule #4). Body is indexed
    # here, unlike Manifest, which tokenizes only id + description; a rare
    # drug name mentioned only in an item's body is exactly the case Bm25
    # exists to recall.
    #
    # A query that is entirely non-alphanumeric (an emoji, punctuation only)
    # tokenizes to nothing on both sides of the FFI boundary and returns [],
    # never an error -- the same tokenless-query behavior Manifest has.
    class Bm25
      # A u32 token-hash collision inside the crate can score a document above
      # zero with an EMPTY surface intersection (no shared tokens to name).
      # Hit#why raises on blank, so that case gets this named fallback rather
      # than a blank string or an exception -- see T8's review panel (Gallant).
      FALLBACK_WHY = "bm25 score match (token-level explanation unavailable)"

      # @param index [#map, #to_h] a Memory::Index snapshot (or any duck that
      #   yields Items and maps id => Item), sent, not stored -- the same
      #   contract Manifest.new already has.
      def initialize(index:)
        items = index.to_a
        @descriptions = items.to_h { |item| [item.id, item.description] }
        # An empty corpus has nothing to score, and the crate refuses to build
        # one (Lain::Ext::Bm25::EmptyCorpus, kept loud for direct ext users).
        # Here it is a legitimate steady state -- a fresh memory index before
        # the first write -- so skip the build and answer [] on search, the
        # same graceful empty behavior Memory::Manifest has over the same duck.
        pairs = items.map { |item| [item.id, "#{item.description}\n#{item.body}"] }
        @engine = pairs.empty? ? nil : Lain::Ext::Bm25.build(pairs)
        @size = items.size
        freeze
      end

      # @param query [String]
      # @param k [Integer, nil] top-k bound; nil (the default) returns every
      #   match, matching Manifest#search's own unbounded shape so a caller
      #   that bounds itself (Context::Recall does, via #first) can treat
      #   either index the same way.
      # @return [Array<Manifest::Hit>] sorted by descending score, ties broken
      #   by build-batch insertion order (pinned in ext/lain/src/bm25.rs); []
      #   on no match.
      # rubocop:disable Naming/MethodParameterName -- `k` is the pinned name
      # from the plan card (T9/T10), matching Context::Recall's own `k:`.
      def search(query, k: nil)
        bound = k.nil? ? @size : Integer(k)
        return [] if @engine.nil? || bound <= 0

        @engine.search(query.to_s, bound).map { |id, score, matched| hit_for(id, score, matched) }
      end
      # rubocop:enable Naming/MethodParameterName

      def to_s
        "#<Lain::Memory::Bm25 entries=#{@size}>"
      end
      alias inspect to_s

      private

      def hit_for(id, score, matched)
        Manifest::Hit.new(id: id, description: @descriptions.fetch(id), score: score.to_f, why: why_for(matched))
      end

      def why_for(matched)
        matched.empty? ? FALLBACK_WHY : "matched tokens: #{matched.sort.join(", ")}"
      end
    end
  end
end
