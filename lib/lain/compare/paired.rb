# frozen_string_literal: true

module Lain
  class Compare
    # Differences between two arms over the tasks both finished, so a gap
    # between arms is not mixed with the gap between easy and hard tasks.
    # A difference is candidate minus baseline; a win is a candidate value above the baseline's.
    Paired = Data.define(:baseline, :candidate, :pairs, :unpaired) do
      # @param baseline [String] the arm the differences are taken from
      # @param candidate [String] the arm compared against it
      # @param values_by_task [Hash{Object=>Array}] task key => [baseline value, candidate value];
      #   a side that is a String is the reason that arm has no value for the task
      def self.of(baseline:, candidate:, values_by_task:)
        paired, unpaired = values_by_task.partition { |_key, sides| sides.all?(Numeric) }
        new(baseline:, candidate:,
            pairs: paired.to_h { |key, (before, after)| [key, after - before] }.freeze,
            unpaired: unpaired.to_h { |key, sides| [key, sides.find { |side| !side.is_a?(Numeric) }] }.freeze)
      end

      def mean_difference = pairs.empty? ? nil : Stats.mean(pairs.values)
      def interval = Stats.mean_interval(pairs.values)
      def wins = pairs.values.count(&:positive?)
      def losses = pairs.values.count(&:negative?)
      def ties = pairs.values.count(&:zero?)
    end
  end
end
