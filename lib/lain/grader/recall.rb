# frozen_string_literal: true

module Lain
  module Grader
    # Recall@k over ONE query: what fraction of that query's gold ids the ranked
    # hits surface within the top k. Scores exactly one query into exactly one
    # {Grade} -- the scalar shape Fixture already uses -- because folding many
    # queries' recall scores into a distribution is Compare's job (grader.rb's
    # module doc: "Compare folds a Grade's #score into its distribution"), not a
    # responsibility this class should invent ahead of that need.
    #
    #   Recall.new(gold_ids: %w[a b c]).grade(%w[a x b], k: 3)
    #   #=> Grade(score: 0.666..., why: "recall@k 2/3: missed b, c" ...)
    class Recall
      # @param gold_ids [Enumerable<#to_s>] the ids that count as a correct hit
      def initialize(gold_ids:)
        @gold_ids = gold_ids.map { |id| -id.to_s }.uniq.freeze
        raise ArgumentError, "gold_ids must not be empty -- recall over no gold answers is meaningless" if
          @gold_ids.empty?

        freeze
      end

      # @param hits [Enumerable] ranked results, most relevant first -- either bare
      #   ids or anything duck-typed with #id (a Memory::Manifest::Hit, a BM25 hit)
      # @param k [Integer, nil] how many ranked hits count; nil considers all of them
      # @return [Grade] score = |gold ids found in the top k| / |gold ids|
      # rubocop:disable Naming/MethodParameterName -- `k` is the pinned name (recall@k),
      # matching Memory::Bm25#search and Context::Recall's own `k:`.
      def grade(hits, k: nil)
        ranked = Array(hits)
        top = k ? ranked.first(k) : ranked
        found = @gold_ids & top.map { |hit| id_of(hit) }
        Grade.new(score: found.size.fdiv(@gold_ids.size), why: explain(found))
      end
      # rubocop:enable Naming/MethodParameterName

      private

      def id_of(hit)
        hit.respond_to?(:id) ? hit.id.to_s : hit.to_s
      end

      def explain(found)
        return "recall@k #{found.size}/#{@gold_ids.size}: all gold ids found" if found.size == @gold_ids.size

        "recall@k #{found.size}/#{@gold_ids.size}: missed #{(@gold_ids - found).sort.join(", ")}"
      end
    end
  end
end
