# frozen_string_literal: true

module Lain
  module Bench
    class PlanSweep
      # Folds the sweep's {Measurement}s into per-arm distributions and renders
      # one titled table per metric, plus wall-clock as an ABSENT section. The
      # Compare-STYLE, ranks-arms-side-by-side shape {ArmSweep::Report} and
      # {Bench::Sweep} share; like them it reuses the two {Compare} pieces that
      # fit verbatim -- {Compare::Distribution} (mean/median/min/max) and
      # {Compare::Table} (aligned rendering) -- rather than reshaping Compare's
      # run-priced surface. No category breakdown (one plan, one task class), so
      # it is flatter than {ArmSweep::Report}: header, notes, the metric tables.
      class Report
        # metric label => how to pull one value off a {Measurement} and render it.
        # Wall-clock is deliberately absent -- it has no honest value under mock
        # replay and rides {#wall_clock_section} as ABSENT instead.
        METRICS = {
          "grader score" => { of: :score, fmt: ->(value) { format("%.3f", value) } },
          "context bytes (token proxy)" => { of: :tokens, fmt: ->(value) { format("%.1f", value) } },
          "cache-writes" => { of: :cache_writes, fmt: ->(value) { format("%.2f", value) } }
        }.freeze
        private_constant :METRICS

        COLUMNS = %w[arm n mean median min max].freeze
        private_constant :COLUMNS

        ABSENT = "ABSENT (mock)"
        private_constant :ABSENT

        NOTES = [
          "NOTE: wall-clock is ABSENT under offline mock replay -- there is no real parallelism to time, and a " \
          "fabricated number for a dry replay would be a lie (measurable only live, absent here).",
          "NOTE: cache-writes are projected by Bench::Rewrites over the mainline's prefix-digest chain, NOT read " \
          "from Usage -- Provider::Mock never populates cache fields (the PC-6 escalation trigger). A cache-write " \
          "is a prefix REWRITE (the warm cached prefix invalidated). Fork-per-step is append-only (zero); linear " \
          "rewrites once per seam; the reactive baseline rewrites when its scheduler forces a warm compaction.",
          "NOTE: grader score is ARM-INVARIANT by construction -- the produced work product depends only on the " \
          "scripted run, never on the compaction shape -- so equal score rows mean 'no shape corrupted the " \
          "output', a reassurance, not a finding. The shape signal lives entirely in tokens and cache-writes.",
          "NOTE: at density `none` there are no plan seams, so no shape action fires and both `linear / none` and " \
          "`fork / none` ARE the one reactive cache-aware-compaction baseline -- identical rows by construction, " \
          "the reference line the plan-shaped arms must beat (the ArmSweep identical-rows precedent)."
        ].freeze
        private_constant :NOTES

        # @param measurements [Array<Measurement>]
        # @param arms [Array<String>] arm labels, in report-row order
        # @param runs [Array<String>] scripted-run ids, for the header count
        def initialize(measurements, arms:, runs:)
          @measurements = measurements
          @arms = arms
          @runs = runs
        end

        # @return [String] never printed here (output discipline)
        def to_s
          [header, "", NOTES.join("\n\n"), "", bodies.join("\n\n")].join("\n")
        end

        private

        def bodies
          METRICS.map { |name, spec| metric_section(name, spec) } + [wall_clock_section]
        end

        def metric_section(name, spec)
          rows = @arms.map do |arm|
            dist = Compare::Distribution.new(values_for(arm, spec.fetch(:of)))
            [label_for(arm), dist.n.to_s, *[dist.mean, dist.median, dist.min, dist.max].map(&spec.fetch(:fmt))]
          end
          "#{name}\n#{Compare::Table.new(headers: COLUMNS, rows:)}"
        end

        # The reactive baseline is marked in the TABLE, not only the notes, so a
        # reader scanning one metric knows which rows are the reference without
        # scrolling back up.
        def label_for(arm) = arm.end_with?("/ none") ? "#{arm} (baseline)" : arm

        # Wall-clock as its own section: one row per arm, n = runs measured, the
        # four stats ABSENT -- the decider/arm-sweep discipline (mark absent,
        # never fabricate) for a metric a dry replay cannot honestly produce.
        def wall_clock_section
          rows = @arms.map { |arm| [label_for(arm), @runs.size.to_s, ABSENT, ABSENT, ABSENT, ABSENT] }
          "wall-clock (s)\n#{Compare::Table.new(headers: COLUMNS, rows:)}"
        end

        def values_for(arm, reader)
          cells = @measurements.select { |measurement| measurement.arm == arm }
          cells.map { |measurement| measurement.public_send(reader) }
        end

        def header
          "Plan-shaped compaction sweep -- #{@arms.size} arms (shapes x densities), " \
            "#{pluralize(@runs.size, "scripted run")}; baseline: reactive / none"
        end

        def pluralize(count, word) = "#{count} #{count == 1 ? word : "#{word}s"}"
      end
    end
  end
end
