# frozen_string_literal: true

module Lain
  module Memory
    # A Manifest::Hit-duck search index (T5) that layers an N-hop
    # `[[wikilink]]` walk over Manifest, the always-runs lexical floor
    # (references/memory-and-retrieval.md #2: "signal, never a gate"). The
    # seed pass IS Manifest#search, unchanged -- Graph never re-implements
    # tokenization or scoring, it only adds items the seed pass could not see
    # because the shared query term lives in a *linked* item, not the seed's
    # own id/description.
    #
    # Link-resolution rule (pinned per the card's escalation trigger): the
    # text inside `[[name]]` is matched, after stripping surrounding
    # whitespace, against Memory::Item#id verbatim -- no case-folding, no
    # Canonical normalization beyond what Item#id already carries. A link
    # naming an id absent from this index's snapshot is silently unreachable
    # (never an error): the same graceful-empty posture Bm25 takes for an
    # empty corpus, because a stale or mistyped wikilink degrading the
    # boosting arm must never surface as a crash in a tool call.
    class Graph
      # Matches [[name]]; a body with no wikilinks yields no matches, so a
      # plain item -- the common case -- pays nothing beyond one #scan.
      LINK = /\[\[([^\[\]]+)\]\]/
      private_constant :LINK

      # Each hop away from a seed halves the hit's score. Never zero for any
      # finite hop count, which keeps every hop hit inside Hit's
      # finite-and-non-negative floor without a separate clamp, and keeps a
      # seed match always outranking anything reached only by crossing a
      # link to it.
      HOP_DECAY = 0.5
      private_constant :HOP_DECAY

      # @param index [#to_a] a Memory::Index snapshot (or any duck yielding
      #   Items), sent, not stored -- the same contract Bm25 and Manifest
      #   already have.
      def initialize(index:)
        items = index.to_a
        @items = items.to_h { |item| [item.id, item] }
        @links = items.to_h { |item| [item.id, links_in(item.body)] }
        @manifest = Manifest.new(items)
        freeze
      end

      # @param query [String]
      # @param hops [Integer] wikilink hops to walk past the seed matches;
      #   0 (the default) is a pure Manifest seed search. A non-positive
      #   value walks zero hops via an empty Range, not a branch.
      # @param k [Integer, nil] top-k bound; nil (the default) returns every
      #   match, matching Bm25's own unbounded-by-default shape.
      # @return [Array<Manifest::Hit>] sorted by (score desc, id asc); []
      #   on no match and nothing reachable from one.
      # rubocop:disable Naming/MethodParameterName -- `k` matches the pinned
      # convention shared with Memory::Bm25#search and Context::Recall's k:.
      def search(query, hops: 0, k: nil)
        seed_hits = @manifest.search(query)
        ordered = (seed_hits + hop_hits(seed_hits, hops)).sort_by { |hit| [-hit.score, hit.id] }
        bound = k.nil? ? ordered.size : Integer(k)
        ordered.first([bound, 0].max)
      end
      # rubocop:enable Naming/MethodParameterName

      def to_s
        "#<Lain::Memory::Graph entries=#{@items.size}>"
      end
      alias inspect to_s

      private

      def links_in(body)
        body.scan(LINK).flatten.map(&:strip).uniq.freeze
      end

      # Only links landing on a known id are traversable -- an unresolved
      # `[[name]]` is simply a dead end, never an error (see the class doc).
      def neighbors(id)
        @links.fetch(id, []).select { |target| @items.key?(target) }
      end

      # Hop hits, one per item first reached by crossing 1..hops links from a
      # seed. Every path recorded is shortest-first by construction (see
      # #paths_by_hop), so the walk never revisits a shorter route with a
      # longer one, and a seed already present never gets a hop duplicate.
      def hop_hits(seed_hits, hops)
        seed_by_id = seed_hits.to_h { |hit| [hit.id, hit] }
        paths_by_hop(seed_by_id.keys, hops)
          .reject { |id, _path| seed_by_id.key?(id) }
          .map { |id, path| hit_for_path(id, path, seed_by_id.fetch(path.first)) }
      end

      # id => shortest path (an Array of ids, seed-first) reachable within
      # `hops` link crossings. Seeded with each seed's length-1 path to
      # itself; (1..hops) is empty for hops <= 0, so the walk itself does the
      # "no expansion" case with no separate branch. Each round looks at
      # every path discovered so far (not only the newest frontier) and
      # keeps the alphabetically-first new path per target, which is what
      # makes the whole walk deterministic independent of item write order.
      def paths_by_hop(seed_ids, hops)
        paths = seed_ids.to_h { |id| [id, [id]] }
        (1..hops).inject(paths) { |acc, _hop| acc.merge(one_more_hop(acc)) }
      end

      # The new id => path entries one hop past every path known so far,
      # first new path per target wins (see #paths_by_hop's doc for why that
      # is deterministic).
      def one_more_hop(known_paths)
        known_paths.flat_map { |id, path| neighbors(id).map { |target| [target, path + [target]] } }
                   .reject { |target, _path| known_paths.key?(target) }
                   .sort_by { |_target, path| path }
                   .each_with_object({}) { |(target, path), found| found[target] ||= path }
      end

      def hit_for_path(id, path, seed_hit)
        item = @items.fetch(id)
        score = seed_hit.score * (HOP_DECAY**(path.length - 1))
        Manifest::Hit.new(id:, description: item.description, score:, why: "reached via #{path.join(" -> ")}")
      end
    end
  end
end
