# frozen_string_literal: true

module Lain
  class Compare
    # The TRANSPOSED fold: rows are ARMS, cells are that arm's {Distribution}
    # over its OWN samples, one titled table per metric.
    #
    # A SIBLING of {Compare}, not a widening of it: Compare folds ONE scalar per
    # {Run} into a distribution ACROSS the runs, so its rows are METRICS. Giving
    # {Run} a metrics Hash would not close the gap -- a Hash of scalars is still
    # one value per run.
    #
    # What is shared is not the axis, it is the CELL ORDER. `HEADERS` names four
    # stat columns and {#stats} names four values; a copy that transposes mean
    # and median still renders four plausible numbers in four columns, mislabels
    # every figure in a bench report, and fails no test, because both cells are
    # numbers of the same shape. One object owns that pairing, with the two
    # declarations adjacent.
    #
    # Its own state is the row LABELLER and nothing else -- what varies per
    # render arrives per call. Formatting a value into a cell stays the caller's
    # job, as it is for {Table}: this object converts nothing, so a BigDecimal
    # cost reaches the formatter as a BigDecimal.
    class ArmFold
      # The shared seven. A report with a column of its own extends this rather
      # than restating it (see {Bench::Sweep}'s COLUMNS).
      HEADERS = %w[arm n mean ci95 median min max].freeze

      # One sample has no spread, so no interval; the cell says so rather than printing a zero-width one.
      NO_INTERVAL = "-"
      private_constant :NO_INTERVAL

      # @param label [#call] arm key => its row label, so a control or baseline
      #   mark reaches every table and not only the header. Identity by default.
      def initialize(label: :itself.to_proc)
        @label = label
        freeze
      end

      # @param metrics [Hash{String=>Hash}] section title => `{of:, fmt:}`, the
      #   metric declaration each sweep already writes; iteration order is
      #   section order
      # @param arms [Array] the arm keys, in report-row order
      # @yieldparam arm [Object] one arm key
      # @yieldparam of [Object] that metric's declared `of:` extractor
      # @yieldreturn [Array<Numeric>] that arm's samples for that metric
      # @return [Array<String>] one "<title>\n<table>" per metric
      def sections(metrics, arms:, &samples)
        metrics.map { |title, spec| section(title, spec, arms, &samples) }
      end

      # "Mark absent, never fabricate", for a metric a dry replay cannot
      # honestly produce. The `n` column stays real: how many samples WOULD
      # have been measured.
      #
      # @return [String]
      def absent_section(title, arms:, count:, marker:)
        titled(title, arms.map { |arm| absent_row(arm, count:, marker:) })
      end

      # Public for the reports that append a column of their own, or assemble
      # their own table, instead of rendering a section per metric.
      #
      # @param arm [Object] the arm key this row labels, the same identity
      #   {#sections}' block receives
      # @param dist [Distribution] that arm's samples, already folded
      # @param fmt [#call] formats one stat value into its cell
      # @return [Array<String>] `HEADERS.size` cells
      def row(arm, dist, fmt:)
        mean, *rest = stats(dist).map(&fmt)
        [@label.call(arm), dist.n.to_s, mean, interval_cell(dist, fmt), *rest]
      end

      # The per-arm case of what {#absent_section} does to a whole table.
      #
      # @return [Array<String>]
      def absent_row(arm, count:, marker:)
        [@label.call(arm), count.to_s, *Array.new(HEADERS.size - 2, marker)]
      end

      private

      def section(title, spec, arms)
        fmt = spec.fetch(:fmt)
        titled(title, arms.map { |arm| row(arm, Distribution.new(yield(arm, spec.fetch(:of))), fmt:) })
      end

      def titled(title, rows) = "#{title}\n#{Table.new(headers: HEADERS, rows:)}"

      def interval_cell(dist, fmt)
        interval = dist.interval
        interval ? "#{fmt.call(interval.low)}..#{fmt.call(interval.high)}" : NO_INTERVAL
      end

      # Written next to HEADERS on purpose: the mean, median, min and max sit
      # under those column names (the interval cell, after the mean, is
      # {#interval_cell}), and nothing else in the codebase may restate either.
      def stats(dist) = [dist.mean, dist.median, dist.min, dist.max]
    end
  end
end
