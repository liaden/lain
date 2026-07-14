# frozen_string_literal: true

module Lain
  module Bench
    # Beam search over agent behaviour. Fork one node into N trajectories, run
    # each, score each, keep the best. This is the payoff of the Timeline being a
    # content-addressed DAG: `#fork` is O(1) identity over a SHARED Store, so N
    # speculative branches cost one shared prefix plus each branch's own tail,
    # never N copies of the history.
    #
    # The grader is injected and only has to answer `#grade(trajectory) -> Grade`
    # -- a {Grader::Fixture} for a deterministic, reproducible search; a
    # {Grader::Rubric} when "best" is a judgment. Selection is `max_by` on the
    # grade's score, and Ruby's `max_by` is stable, so ties resolve toward the
    # earliest branch and the whole search is reproducible.
    class Speculative
      # One explored trajectory: which branch produced it, the trajectory itself
      # (typically a Timeline), and its grade.
      Candidate = Data.define(:index, :trajectory, :grade)

      # The search's outcome: the winning trajectory, its grade, and every
      # candidate ranked, so a caller can inspect the road not taken.
      Selection = Data.define(:best, :grade, :candidates) do
        def score = grade.score
      end

      # @param grader [#grade] scores a trajectory into a Grade
      def initialize(grader:)
        @grader = grader
      end

      # Fork `timeline` into one trajectory per branch, score each, select the
      # max.
      #
      # @param timeline [Lain::Timeline] the node to speculate from
      # @param branches [Array<#call(Timeline)>] each maps the forked Timeline to
      #   a trajectory the grader can score
      # @return [Selection]
      # @raise [ArgumentError] on an empty beam
      def search(timeline, branches:)
        beam = Array(branches)
        raise ArgumentError, "speculative search needs at least one branch" if beam.empty?

        candidates = beam.each_with_index.map { |branch, index| explore(timeline, branch, index) }
        best = candidates.max_by { |candidate| candidate.grade.score }
        Selection.new(best: best.trajectory, grade: best.grade, candidates:)
      end

      private

      # `#fork` is identity, so each branch starts from the same immutable node
      # and diverges by committing -- the divergence, not the fork, is what
      # allocates.
      def explore(timeline, branch, index)
        trajectory = branch.call(timeline.fork)
        Candidate.new(index:, trajectory:, grade: @grader.grade(trajectory))
      end
    end
  end
end
