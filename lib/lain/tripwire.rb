# frozen_string_literal: true

module Lain
  # What would stop an agent that keeps probing the boundary. A {Ledger} folds
  # the session's journal into a score per requester and journals a `tripwire`
  # record for each signal it counts, so a bench run can price the false trips.
  # Under the stop arm a seeded signal past the hard stop also trips {Stops}:
  # it records who is stopped or paused, journals a `tripwire_stop` record, and
  # holds that state for {Middleware::TripwireStop} to refuse calls by.
  module Tripwire
    Rules = Data.define(:points, :hard_stop)

    # How much each weight of signal counts, and the score at which a requester
    # would be stopped. A strong signal alone trips it: a refused exec, a loader
    # or descriptor exec and a planted program are each what an honest call does
    # not do. The numbers are taste until observe-only runs measure them.
    class Rules
      WEIGHTS = %i[strong medium weak].freeze
      WOULD_STOP = "would_stop"
      NONE = "none"

      # @param points [Hash{Symbol=>Integer}] per weight in {WEIGHTS}
      # @param hard_stop [Integer] the score a requester is stopped at
      def initialize(points:, hard_stop:)
        super(points: points.slice(*WEIGHTS).freeze, hard_stop:)
      end

      # @param weight [Symbol] one of {WEIGHTS}
      # @return [Integer]
      def points_for(weight) = points.fetch(weight)

      # @param score [Integer]
      # @return [String] {WOULD_STOP} at or past the hard stop, else {NONE}
      def stop_for(score) = score >= hard_stop ? WOULD_STOP : NONE

      DEFAULT = new(points: { strong: 10, medium: 3, weak: 1 }, hard_stop: 10)
    end
  end
end
