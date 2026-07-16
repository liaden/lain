# frozen_string_literal: true

module Lain
  module Memory
    # A Manifest::Hit-duck search index (T14) fusing two ALREADY-BUILT arms
    # by Reciprocal Rank Fusion (RRF) -- the fourth boosting arm over the
    # Manifest floor (references/memory-and-retrieval.md #2), and the first
    # one that combines two OTHER arms' rankings rather than scoring the
    # corpus itself.
    #
    # @bm25 and @vector are INJECTED, not constructed: Hybrid owns fusion,
    # not corpus indexing, so it depends on the two `#search`-duck
    # collaborators exactly the way Context::Recall depends on an
    # already-built index instead of building one (CLAUDE.md: "inject
    # collaborators rather than construct them"). Any Manifest::Hit-duck
    # index can stand in for either arm -- nothing here names Bm25 or
    # Vector's classes, only the labels `:bm25`/`:vector` in #why.
    #
    # RRF reads only each arm's RANK POSITION, never the arm's own #score:
    # Bm25's token-fraction-ish scale and Vector's cosine scale are
    # deliberately not comparable (the shared law group's own note, spec/
    # support/shared_examples/memory_index_laws.rb), and RRF's whole design
    # point is that rank position is the one thing every ranking already
    # agrees how to compare. A document ranking consistently mid-table in
    # both arms can therefore outrank a document that tops one arm and
    # trails badly in the other -- fusion resolving a disagreement neither
    # arm could resolve alone.
    class Hybrid
      # Cormack, Clarke & Buettcher, SIGIR 2009 ("Reciprocal Rank Fusion
      # Outperforms Condorcet and Individual Rank Learning Methods"): k=60
      # is the paper's own reported constant, chosen there to damp the
      # influence of any single source's very top ranks without per-corpus
      # tuning. Fixed here for the same reason -- a value FIT to a corpus
      # would make one run's ranking depend on which corpus tuned it, and
      # this bench's premise is that a ranking must be reproducible from the
      # query and the corpus alone, never from a knob turned per fixture.
      RRF_K = 60
      private_constant :RRF_K

      # The two arms fused, in the fixed order #why lists them.
      SOURCES = %i[bm25 vector].freeze
      private_constant :SOURCES

      # The score a document earns when it ranks #1 in BOTH arms -- the
      # ceiling RRF can reach at RRF_K over SOURCES.size arms. Manifest's Hit
      # doc (manifest.rb) says a future boosting arm that exceeds the
      # family's own 0..1 scale "must renormalize"; raw RRF terms are small
      # fractions (1/(RRF_K + rank), at most 1/61 per arm here) that clear
      # Hit's finite-and-non-negative floor without ever approaching 1.0 --
      # satisfying the LETTER of the invariant while leaving the number
      # meaningless next to Manifest/Bm25/Vector's own 0..1 scores. Dividing
      # by this ceiling rescales into 0..1 honestly: 1.0 means "the best a
      # fused rank can be" (both arms' #1), not "some raw sum in the
      # thousandths." Derived from SOURCES.size, never fit to a corpus.
      CEILING = SOURCES.size.fdiv(RRF_K + 1)
      private_constant :CEILING

      # @param bm25 [#search] an already-built Memory::Bm25 (or any
      #   Manifest::Hit-duck index), sent, not stored beyond the reference --
      #   the same injection contract Context::Recall's `index:` has.
      # @param vector [#search] an already-built Memory::Vector (or duck).
      def initialize(bm25:, vector:)
        @bm25 = bm25
        @vector = vector
        freeze
      end

      # @param query [String]
      # @param k [Integer, nil] top-k bound; nil (the default) returns every
      #   fused match, matching Bm25/Vector/Graph's own unbounded-by-default
      #   shape.
      # @return [Array<Manifest::Hit>] sorted by (score desc, id asc); []
      #   when both arms find nothing.
      # rubocop:disable Naming/MethodParameterName -- `k` matches the pinned
      # convention shared with Memory::Bm25#search, Memory::Vector#search,
      # Memory::Graph#search and Context::Recall's k:.
      def search(query, k: nil)
        fused = fuse(ranks_by_source(query))
        bound = k.nil? ? fused.size : Integer(k)
        fused.first([bound, 0].max)
      end
      # rubocop:enable Naming/MethodParameterName

      def to_s
        "#<Lain::Memory::Hybrid>"
      end
      alias inspect to_s

      private

      def ranks_by_source(query)
        { bm25: ranked(@bm25, query), vector: ranked(@vector, query) }
      end

      # id => [1-based rank, Hit], over the arm's OWN unbounded search --
      # fusion needs a source's full ranking, never a k-bounded slice a
      # caller's k would truncate before fusion ever saw the rest of it.
      def ranked(source, query)
        source.search(query).each_with_index.to_h { |hit, index| [hit.id, [index + 1, hit]] }
      end

      def fuse(ranks)
        ids = SOURCES.flat_map { |name| ranks.fetch(name).keys }.uniq
        ids.map { |id| hit_for(id, ranks) }.sort_by { |hit| [-hit.score, hit.id] }
      end

      def hit_for(id, ranks)
        contributions = SOURCES.to_h { |name| [name, ranks.fetch(name)[id]] }
        present = contributions.values.compact
        score = present.sum { |rank, _hit| 1.0 / (RRF_K + rank) } / CEILING
        Manifest::Hit.new(id:, description: present.first.last.description, score:, why: why_for(contributions))
      end

      # Cites BOTH source ranks, always -- a doc surfaced by only one arm
      # names the other as "unranked" rather than omitting it, so #why is
      # never a partial explanation of a fused score.
      def why_for(contributions)
        SOURCES.map { |name| why_for_source(name, contributions.fetch(name)) }.join(", ")
      end

      def why_for_source(name, contribution)
        contribution.nil? ? "#{name} unranked" : "#{name} rank #{contribution.first}"
      end
    end
  end
end
