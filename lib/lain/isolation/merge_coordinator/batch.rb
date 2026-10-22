# frozen_string_literal: true

module Lain
  module Isolation
    module MergeCoordinator
      # Lands a list of workers as few verified candidates as it can. A green
      # batch costs one verify. A red one is split in half, order kept, and
      # each half lands in turn, so the second half is built on whatever the
      # first moved the branch to; a worker failing on its own is ejected.
      #
      # A branch that moved during verification makes the candidate stale
      # rather than wrong, so the batch is built again, up to the cap: past it,
      # the branch is too busy for a verify to keep up with.
      class Batch
        # A worker that conflicted or failed never reached the candidate, so
        # no verification judged it.
        UNHELD = %i[conflicted failed].freeze

        # `verifications` runs beside `reports`: the verification of the run
        # that last ran for each worker (a skip included), or nil where the
        # candidate never held it.
        # `verifies` counts the runs a verifier judged, and `rebuilds` the runs
        # repeated because the branch moved under one, across the whole batch.
        Outcome = Data.define(:reports, :verifications, :verifies, :rebuilds) do
          def initialize(reports:, verifications:, verifies:, rebuilds:)
            super(reports: reports.dup.freeze, verifications: verifications.dup.freeze, verifies:, rebuilds:)
          end
        end

        # @param queue_for [#call] answers a fresh {LandingQueue} per run
        # @param rebuild_cap [Integer] how many times, across the whole batch,
        #   a run is built again after the branch moved during its verification
        def initialize(queue_for:, rebuild_cap:)
          @queue_for = queue_for
          @rebuild_cap = Integer(rebuild_cap)
        end

        # @param workers [Array<LandingQueue::Worker>] in landing order
        # @return [Outcome] one {WorkerHandoff::Report} per worker, in the order given
        def call(workers)
          landed(workers.to_a, Outcome.new(reports: [], verifications: [], verifies: 0, rebuilds: 0))
        end

        private

        # The tally threads through every run, halves included, so the
        # rebuild cap is the batch's budget rather than each half's.
        def landed(workers, tally)
          result = @queue_for.call.call(workers)
          counted = judged?(result) ? tally.with(verifies: tally.verifies + 1) : tally
          return rebuilt(workers, result, counted) if result.stale_tip
          return bisected(workers, counted) if result.verification.outcome == :failed && workers.size > 1

          concluded(counted, reports(workers, result), result)
        end

        def judged?(result) = result.verification.outcome != :skipped

        def rebuilt(workers, result, tally)
          return landed(workers, tally.with(rebuilds: tally.rebuilds + 1)) if tally.rebuilds < @rebuild_cap

          detail = "the branch moved #{times(tally.rebuilds + 1)} during verification"
          concluded(tally, reports(workers, result).map { |report| moving(report, detail) }, result)
        end

        def bisected(workers, tally)
          workers.each_slice((workers.size + 1) / 2).inject(tally) { |sum, half| landed(half, sum) }
        end

        def concluded(tally, reports, result)
          held = reports.map { |report| held?(report) ? result.verification : nil }
          tally.with(reports: tally.reports + reports, verifications: tally.verifications + held)
        end

        def held?(report) = !UNHELD.include?(report.kind)

        def reports(workers, result) = workers.map { |worker| result.report(worker.id) }

        # Only a worker the desk declined was waiting on the branch; one that
        # conflicted or was already landed says something truer than "it moved".
        def moving(report, detail) = report.kind == :declined ? report.with(detail:) : report

        def times(count) = count == 1 ? "once" : "#{count} times"
      end
    end
  end
end
