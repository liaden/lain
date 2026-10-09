# frozen_string_literal: true

module Lain
  module Bench
    # A figure with nothing to divide by is nil, because a zero would read as a
    # measurement of a free landing.
    class LandingMetrics
      # Named by string, not by {Telemetry::LandingBatch}, so a fold survives a
      # journal it was never handed the class for.
      LANDING_BATCH = "landing_batch"

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @return [LandingMetrics]
      def self.from_journal(entries)
        new(Journal.records(entries, type: LANDING_BATCH).to_a)
      end

      # @param batches [Array<Hash>] raw `landing_batch` journal records
      def initialize(batches)
        @batches = batches.freeze
      end

      # @return [Float, nil] verifies per landed commit
      def verifies_per_landed = ratio(sum("verifies"), landed_count)

      # @return [Float, nil] verify wall seconds per landed commit
      def verify_wall_per_landed = ratio(sum("verify_wall_s"), landed_count)

      # @return [Float, nil] rebuilds per batch
      def rebuilds_per_batch = ratio(sum("rebuilds"), @batches.size)

      # @return [Float, nil] share of batch members that were ejected
      def ejected_share = ratio(sum_sizes("ejected"), sum_sizes("worker_keys"))

      # @return [Float, nil] median seconds a landed commit waited in the queue
      def queue_wait_p50 = percentile(50)

      # @return [Float, nil] 95th percentile seconds a landed commit waited in the queue
      def queue_wait_p95 = percentile(95)

      private

      def landed_count = sum_sizes("landed")

      def sum(field) = @batches.sum { |batch| batch.fetch(field) }

      def sum_sizes(field) = @batches.sum { |batch| batch.fetch(field).size }

      def ratio(numerator, denominator) = denominator.zero? ? nil : numerator.to_f / denominator

      def percentile(share)
        waits = landed_waits.sort
        waits[(share * waits.size / 100.0).ceil - 1] unless waits.empty?
      end

      def landed_waits
        @batches.flat_map do |batch|
          waits = batch.fetch("queue_wait_s")
          batch.fetch("landed").map { |key| waits.fetch(key) }
        end
      end
    end
  end
end
