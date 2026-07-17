# frozen_string_literal: true

module Lain
  module Memory
    # A Manifest::Hit-duck search index (T10) over an injected {Embedder}: an
    # exact (no ANN) cosine ranking over embeddings, the third boosting arm
    # alongside Bm25 (lexical) and Graph (wikilink) -- Manifest stays the
    # always-runs floor these only rank on top of
    # (references/memory-and-retrieval.md #2).
    #
    # Items are embedded ONCE at construction, in one batched #embed call --
    # Bm25's build-once shape (bm25.rb:32-42), and the same reason the
    # Embedder seam itself is batched (see embedder.rb): crossing a network
    # or FFI boundary once per corpus, never once per item. A search query is
    # a second, single-text batch call, never one call per candidate.
    #
    # Not a Rust binding candidate: cosine over a handful of item vectors is
    # neither hot per-turn (CLAUDE.md rule 3) nor a data structure Ruby's
    # object model makes asymptotically worse (rule 2) -- it is a handful of
    # Array#sum calls, which is exactly the shape that stays in Ruby.
    class Vector
      # @param index [#to_a] a Memory::Index snapshot (or any duck yielding
      #   Items), sent, not stored -- the same contract Bm25 and Graph have.
      # @param embedder [#embed] the Embedder duck: #embed(texts) ->
      #   [[Float]], one equal-dimension vector per input text, in order.
      #   Injected, never constructed -- Embedder::Static is the deterministic
      #   bench arm this class is unit-tested against; Ollama is the same duck
      #   for a live sweep.
      def initialize(index:, embedder:)
        @embedder = embedder
        @embedder_id = embedder.class.name
        @items = index.to_a
        @vectors = @items.empty? ? [] : @embedder.embed(@items.map { |item| "#{item.description}\n#{item.body}" })
        # Norms depend only on the vectors embedded above, so they are paid
        # once here instead of once per search -- a norm is itself a full dot,
        # and #search was recomputing every item's on every query.
        @norms = @vectors.map { |vector| norm(vector) }
        freeze
      end

      # @param query [String]
      # @param k [Integer, nil] top-k bound; nil (the default) returns every
      #   positive match, matching Bm25's own unbounded-by-default shape.
      # @return [Array<Manifest::Hit>] sorted by (score desc, id asc); []
      #   on an empty index and on a query that embeds to the zero vector (an
      #   entirely out-of-vocabulary query under Static -- cosine against the
      #   zero vector is undefined, so it is "no match," never a NaN score).
      # rubocop:disable Naming/MethodParameterName -- `k` matches the pinned
      # convention shared with Memory::Bm25#search and Memory::Graph#search.
      def search(query, k: nil)
        bound = k.nil? ? @items.size : Integer(k)
        return [] if @items.empty? || bound <= 0

        candidates_for(query).first(bound)
      end
      # rubocop:enable Naming/MethodParameterName

      def to_s
        "#<Lain::Memory::Vector entries=#{@items.size} embedder=#{@embedder_id}>"
      end
      alias inspect to_s

      private

      # The query's own single-text batch call (never one call per
      # candidate, see the class doc), scored against every stored vector.
      # A query embedding to the zero vector (entirely out-of-vocabulary
      # under Static) has nothing to be cosine-similar to, so it is "no
      # match" here rather than a NaN slipping into #hit_for.
      def candidates_for(query)
        query_vector = @embedder.embed([query.to_s]).first
        query_norm = norm(query_vector)
        return [] if query_norm.zero?

        @items.zip(@vectors, @norms)
              .filter_map { |item, vector, item_norm| hit_for(item, vector, item_norm, query_vector, query_norm) }
              .sort_by { |hit| [-hit.score, hit.id] }
      end

      # A zero-norm item vector (its text shares no vocabulary with the
      # embedder) makes cosine 0/0 -- undefined, so the item is excluded
      # rather than scored. A negative cosine is excluded the same way
      # Manifest excludes a zero token-fraction: from the RANKING, not the
      # index (Hit's own floor is finite-and-non-negative, so a negative
      # score could never become a Hit anyway; the guard here is what keeps
      # that floor a design choice instead of a rescued exception).
      def hit_for(item, vector, item_norm, query_vector, query_norm)
        return nil if item_norm.zero?

        score = dot(vector, query_vector) / (item_norm * query_norm)
        return nil unless score.positive?

        Manifest::Hit.new(id: item.id, description: item.description, score:, why: why_for(score))
      end

      # Index-walked rather than zip'd: this is the sweep's hottest loop, and
      # `zip` allocates one pair Array per element for bytes `sum` immediately
      # discards -- the pairs alone were ~a quarter of the bench suite's wall
      # time and most of its GC. Same Enumerable#sum (same compensated float
      # summation, same order), no intermediates.
      def dot(vec_a, vec_b)
        (0...vec_a.size).sum { |i| vec_a[i] * vec_b[i] }
      end

      def norm(vector)
        Math.sqrt(dot(vector, vector))
      end

      def why_for(score)
        format("cosine %<score>.4f via %<embedder_id>s", score:, embedder_id: @embedder_id)
      end
    end
  end
end
