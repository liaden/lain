# frozen_string_literal: true

module Lain
  module Grader
    # One query into one {Grade}; folding queries is {Compare}'s job.
    class Ndcg
      GRADES = (0..3)

      # @param relevance [Hash{String=>Integer}] id => grade 0..3
      def initialize(relevance:)
        @relevance = relevance.to_h { |id, grade| [Hits.id_of(id), check_grade(grade)] }.freeze
        raise ArgumentError, "relevance needs at least one positive grade" unless @relevance.values.any?(&:positive?)

        @ideal_gains = @relevance.values.sort.reverse.map { |grade| gain(grade) }.freeze

        freeze
      end

      # @param hits [Enumerable] ranked results, most relevant first; bare ids or anything with #id
      # @param depth [Integer] how many ranked hits count
      # @return [Grade] score = DCG of the hits / DCG of the ideal ordering, both cut at depth
      def grade(hits, depth: 10)
        gains = Array(hits).first(depth).map { |hit| gain(@relevance.fetch(Hits.id_of(hit), 0)) }
        score = dcg(gains) / dcg(@ideal_gains.first(depth))
        Grade.new(score:, why: "ndcg@#{depth} #{format("%.3f", score)}")
      end

      private

      def check_grade(grade)
        raise ArgumentError, "relevance grades run #{GRADES}, got #{grade.inspect}" unless GRADES.cover?(grade)

        grade
      end

      def gain(grade) = (2**grade) - 1

      def dcg(gains) = gains.each_with_index.sum(0.0) { |gain, rank| gain / Math.log2(rank + 2) }
    end
  end
end
