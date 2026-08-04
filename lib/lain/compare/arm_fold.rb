# frozen_string_literal: true

module Lain
  class Compare
    # The TRANSPOSED fold: rows are ARMS, cells are that arm's {Distribution}
    # over its OWN samples, laid out as one titled table per metric. Every
    # arms-side-by-side bench report needs it -- {Bench::ArmSweep::Report},
    # {Bench::PlanSweep::Report}, {Bench::Sweep}, and {Bench::DeciderSweep}'s
    # wall-clock section -- and each had written it out again.
    #
    # It is a SIBLING of {Compare}, not a widening of it, and those reports'
    # class comments were right about why: Compare folds ONE scalar per {Run}
    # into a distribution ACROSS the runs, so Compare's rows are METRICS. Here
    # each row is an ARM holding a whole sample vector, so the axis is
    # transposed. Giving {Run} a metrics Hash would not close that gap -- a Hash
    # of scalars is still one value per run.
    #
    # What was left to share is not the axis, it is the CELL ORDER. `HEADERS`
    # names four stat columns and {#stats} names four values; a copy that
    # transposes mean and median still renders four plausible numbers in four
    # columns, mislabels every figure in a bench report, and fails no test,
    # because both cells are numbers of the same shape. One object owns that
    # pairing, with the two declarations adjacent.
    #
    # TWO hand-rolled copies of the pairing deliberately remain, both outside
    # this card's reach and both still able to drift:
    #
    # * {Arm::Driver}'s `section` (arm/driver.rb) -- the arm substrate's file.
    #   It should adopt {#row}, NOT {#sections}: `distributions_for` already
    #   holds a {Distribution} per metric, and #sections yields raw sample
    #   arrays, so routing it through #sections would mean re-wrapping
    #   `dist.values` into a second Distribution for no gain.
    # * {Bench::DisclosureSweep}'s `row_for` (disclosure_sweep.rb) -- frozen
    #   pending the seam triage that may delete the class. It can adopt {#row}
    #   the way {Bench::Sweep} does, but it CANNOT extend `HEADERS`: its stat
    #   columns are renamed (`tokens mean`, `tokens median`, ...) rather than
    #   appended to, so either its headings stay local or the fold grows a
    #   column-prefix parameter -- a design step, not a mechanical swap.
    #
    # Its own state is the row LABELLER and nothing else -- what varies per
    # render (the arms, the metrics, an absent marker) arrives per call, so no
    # call site carries a member it does not use. Formatting a value into a cell
    # stays the caller's job, as it is for {Table}: each metric declares its own
    # `fmt`, and this object converts nothing, so a BigDecimal cost reaches the
    # formatter as a BigDecimal.
    class ArmFold
      # The shared six. A report with a column of its own extends this rather
      # than restating it (see {Bench::Sweep}'s COLUMNS).
      HEADERS = %w[arm n mean median min max].freeze

      # @param label [#call] arm key => its row label, so a control or baseline
      #   mark reaches every table and not only the header. Identity by default.
      def initialize(label: :itself.to_proc)
        @label = label
        freeze
      end

      # @param metrics [Hash{String=>Hash}] section title => `{of:, fmt:}`, the
      #   metric declaration each sweep already writes. Iteration order is
      #   section order.
      # @param arms [Array] the arm keys, in report-row order
      # @yieldparam arm [Object] one arm key
      # @yieldparam of [Object] that metric's declared `of:` extractor
      # @yieldreturn [Array<Numeric>] that arm's samples for that metric
      # @return [Array<String>] one "<title>\n<table>" per metric
      def sections(metrics, arms:, &samples)
        metrics.map { |title, spec| section(title, spec, arms, &samples) }
      end

      # A section whose four stats read as `marker` -- the "mark absent, never
      # fabricate" discipline for a metric a dry replay cannot honestly produce.
      # The `n` column stays real: how many samples WOULD have been measured.
      #
      # @return [String]
      def absent_section(title, arms:, count:, marker:)
        titled(title, arms.map { |arm| absent_row(arm, count:, marker:) })
      end

      # One measured row. Public for the reports that append a column of their
      # own, or assemble their own table, instead of rendering a section per
      # metric.
      #
      # @param arm [Object] the arm key this row labels, the same identity
      #   {#sections}' block receives
      # @param dist [Distribution] that arm's samples, already folded
      # @param fmt [#call] formats one stat value into its cell; the caller's job,
      #   never this object's, so a BigDecimal cost reaches it as a BigDecimal
      # @return [Array<String>] `HEADERS.size` cells
      def row(arm, dist, fmt:)
        [@label.call(arm), dist.n.to_s, *stats(dist).map(&fmt)]
      end

      # One row marked absent while its siblings stay measured -- the per-arm
      # case of what {#absent_section} does to a whole table.
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

      # Written next to HEADERS on purpose: these four values sit under those
      # four column names, and nothing else in the codebase may restate either.
      def stats(dist) = [dist.mean, dist.median, dist.min, dist.max]
    end
  end
end
