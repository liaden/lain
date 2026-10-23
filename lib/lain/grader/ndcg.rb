# frozen_string_literal: true

module Lain
  module Grader
    # One query into one {Grade}; folding queries is {Compare}'s job.
    class Ndcg
      GRADES = (0..3)

      # @param relevance [Hash{String=>Integer}] id => grade 0..3
      def initialize(relevance:)
        @relevance = relevance.to_h { |id, grade| [-id.to_s, check_grade(grade)] }.freeze
        raise ArgumentError, "relevance needs at least one positive grade" unless @relevance.values.any?(&:positive?)

        @ideal_gains = @relevance.values.sort.reverse.map { |grade| gain(grade) }.freeze

        freeze
      end

      # @param hits [Enumerable] ranked results, most relevant first; bare ids or anything with #id
      # @param k [Integer] how many ranked hits count
      # @return [Grade] score = DCG of the hits / DCG of the ideal ordering, both cut at k
      # rubocop:disable-next Naming/MethodParameterName -- `k` is the pinned name, as in Recall.
      def grade(hits, k: 10)
        gains = Array(hits).first(k).map { |hit| gain(@relevance.fetch(id_of(hit), 0)) }
        score = dcg(gains) / dcg(@ideal_gains.first(k))
        Grade.new(score:, why: "ndcg@#{k} #{format("%.3f", score)}")
      end

      private

      def check_grade(grade)
        raise ArgumentError, "relevance grades run #{GRADES}, got #{grade.inspect}" unless GRADES.cover?(grade)

        grade
      end

      def gain(grade) = (2**grade) - 1

      def dcg(gains) = gains.each_with_index.sum(0.0) { |gain, rank| gain / Math.log2(rank + 2) }

      def id_of(hit) = hit.respond_to?(:id) ? hit.id.to_s : hit.to_s
    end
  end
end
