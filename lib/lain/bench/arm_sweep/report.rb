# frozen_string_literal: true

module Lain
  module Bench
    class ArmSweep
      # Folds the sweep's {Measurement}s into per-arm distributions and renders
      # them, one titled table per metric, under an "all tasks" section and one
      # per category. This is the Compare-STYLE, ranks-arms-side-by-side shape
      # {Arm::Driver} and {Bench::Sweep} share; like them it reuses only the two
      # {Compare} pieces that fit verbatim -- {Compare::Distribution} (the
      # mean/median/min/max value object) and {Compare::Table} (the aligned
      # renderer) -- rather than reshaping Compare's own run-priced surface.
      #
      # It does NOT subclass {Arm::Driver}: the Driver folds ONE shared seam over
      # a flat task list into three fixed metrics, whereas this sweep carries
      # per-arm recordings, two extra process metrics (context-loss,
      # replans/stalls), and a per-category breakdown the boundary depends on --
      # so it reuses the Driver's building blocks and its report shape, not its
      # fixed folding.
      class Report
        # metric label => how to pull one value off a {Measurement} and render
        # it. Wall-time is deliberately absent: it has no honest value under a
        # mock replay and rides {#wall_time_section} as ABSENT instead.
        METRICS = {
          "grader score" => { of: :score, fmt: ->(value) { format("%.3f", value) } },
          "total tokens" => { of: :tokens, fmt: ->(value) { format("%.1f", value) } },
          "context-loss events" => { of: :context_loss, fmt: ->(value) { format("%.2f", value) } },
          "replans/stalls" => { of: :replans, fmt: ->(value) { format("%.2f", value) } }
        }.freeze
        private_constant :METRICS

        COLUMNS = %w[arm n mean median min max].freeze
        private_constant :COLUMNS

        ABSENT = "ABSENT (mock)"
        private_constant :ABSENT

        NOTES = [
          "NOTE: wall-time is ABSENT under offline mock replay -- it is meaningful only under real " \
          "parallelism, and a fabricated number for a dry replay would be a lie (recorded live, absent here).",
          "NOTE: context-loss uses the control-divergence heuristic -- the lineage/frustration projection " \
          "reads tool-call journals these tool-free arms do not emit, so a produced file diverging from the " \
          "single-thread control counts as one lost-context event (documented reduced fidelity). It " \
          "UNDER-counts: ONLY same-path content divergence is counted; a file the arm omitted or added " \
          "versus the control is not.",
          "NOTE: single-thread and dual-ledger produce IDENTICAL grade and token rows here -- under " \
          "prompt-keyed replay both are linear over the same task prompt, so this tie is an artifact of the " \
          "offline harness, NOT a finding. Dual-ledger's cost is coordination overhead, visible only in the " \
          "replans/stalls metric."
        ].freeze
        private_constant :NOTES

        # @param measurements [Array<Measurement>]
        # @param order [Array<String>] recorded task ids, for the header's counts
        def initialize(measurements, order:)
          @measurements = measurements
          @order = order
        end

        # @return [String] never printed here (output discipline)
        def to_s
          [header, "", NOTES.join("\n"), "", sections.join("\n\n")].join("\n")
        end

        private

        # A category with no tasks (a single-category fixture) is OMITTED rather
        # than rendered as an empty table -- an empty distribution has no median
        # to fold, and a blank section discloses nothing.
        def sections
          { "All tasks" => @measurements, "procedural" => by_category(:procedural),
            "parallel" => by_category(:parallel) }
            .reject { |_label, subset| subset.empty? }
            .map { |label, subset| category_block(label, subset) }
        end

        def by_category(category) = @measurements.select { |measurement| measurement.category == category }

        def category_block(label, subset)
          bodies = METRICS.map { |name, spec| metric_section(name, spec, subset) } + [wall_time_section(subset)]
          "== #{label} ==\n\n#{bodies.join("\n\n")}"
        end

        def metric_section(name, spec, subset)
          rows = ARM_ORDER.map do |arm|
            dist = Compare::Distribution.new(values_for(subset, arm, spec.fetch(:of)))
            [label_for(arm), dist.n.to_s, *[dist.mean, dist.median, dist.min, dist.max].map(&spec.fetch(:fmt))]
          end
          "#{name}\n#{Compare::Table.new(headers: COLUMNS, rows:)}"
        end

        # The control is marked in the TABLE, not only the header, so a reader
        # scanning one metric still knows which row every other arm is measured
        # against without scrolling back up.
        def label_for(arm) = arm == ARM_ORDER.first ? "#{arm} (control)" : arm

        # Wall-time as its own section: one row per arm, n = tasks measured, the
        # four stats ABSENT -- the decider-sweep discipline (mark absent, never
        # fabricate) for a metric a dry replay cannot honestly produce.
        def wall_time_section(subset)
          n = subset.count { |measurement| measurement.arm == ARM_ORDER.first }.to_s
          rows = ARM_ORDER.map { |arm| [label_for(arm), n, ABSENT, ABSENT, ABSENT, ABSENT] }
          "wall-time (s)\n#{Compare::Table.new(headers: COLUMNS, rows:)}"
        end

        def values_for(subset, arm, reader)
          subset.select { |measurement| measurement.arm == arm }.map { |measurement| measurement.public_send(reader) }
        end

        def header
          procedural = distinct_tasks(:procedural)
          parallel = distinct_tasks(:parallel)
          "Arm sweep — #{pluralize(@order.size, "task")} (#{procedural} procedural, #{parallel} parallel), " \
            "#{ARM_ORDER.size} arms (#{ARM_ORDER.join(" vs ")}); control: single-thread"
        end

        def pluralize(count, word) = "#{count} #{count == 1 ? word : "#{word}s"}"

        def distinct_tasks(category)
          @measurements.select { |m| m.category == category }.map(&:task_id).uniq.size
        end
      end
    end
  end
end
