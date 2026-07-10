# frozen_string_literal: true

require "bigdecimal"

require_relative "capability/degraded_set"
require_relative "capability/guard"
require_relative "ledger"
require_relative "usage"

module Lain
  # Compares n>=2 runs by DISTRIBUTION, because a single A/B is noise: one run
  # each of two arms tells you nothing about whether the difference you see is
  # the tactic or the variance. So Compare folds each metric -- total tokens,
  # cache-hit ratio, cost, grader score -- into a distribution across the runs
  # and reports mean/median/min/max.
  #
  # It also REFUSES, up front, to compare runs whose {Capability::DegradedSet}s
  # differ. If one arm silently lost `:thinking` and the other kept it, half the
  # tactic under study never ran on that arm and the comparison measures the
  # missing capability, not the variable. {Capability::Guard} raises rather than
  # reports -- a lie you can read is worse than an error you cannot ignore.
  #
  # The report is a DX artifact, not a debug dump: a scannable per-metric table,
  # returned as a String (nothing here touches stdout).
  class Compare
    # One run's measured outcome, in the vocabulary Compare aggregates. Built
    # either directly from measured metrics or, more usually, from a recorded
    # Timeline via {.from_timeline}, which prices it through the {Ledger}.
    Run = Data.define(:name, :usage, :cost, :score, :degraded) do
      # @param timeline [Lain::Timeline] the recorded run
      # @param ledger [Lain::Ledger] usage + cost, deduped by content-address
      # @param grade [#score, nil] a grader's verdict, if the run was graded
      # @param degraded [Capability::DegradedSet] what this run silently lost
      def self.from_timeline(name:, timeline:, ledger: Ledger.new, grade: nil,
                             degraded: Capability::DegradedSet.new([]))
        new(name: name, usage: ledger.usage(timeline), cost: ledger.cost(timeline),
            score: grade&.score, degraded: degraded)
      end

      def initialize(name:, usage:, cost:, degraded:, score: nil)
        super(name: -name.to_s, usage: usage, cost: cost, score: score, degraded: degraded)
      end

      def total_tokens = usage.total_tokens
      def cache_hit_ratio = usage.cache_hit_ratio
      def graded? = !score.nil?
    end

    # The shape of one metric across the runs. Numeric-type-preserving on
    # purpose: cost stays BigDecimal through the fold so a dollar figure never
    # drifts (BigDecimal `/` is true division), while an Integer-valued metric
    # like total tokens must use `fdiv` -- plain `Integer#/` FLOORS, which would
    # report `[1000, 1000, 1001].mean` as 1000 and then print it as a
    # fake-precise "1000.0". `#divide` routes each type to the division that
    # keeps it honest.
    #
    # Frozen deeply (the values array and its members) so a Distribution clears
    # the project's `Ractor.shareable?` bar, like every other value object here.
    Distribution = Data.define(:values) do
      def initialize(values:)
        super(values: values.map(&:freeze).freeze)
      end

      def n = values.size
      def mean = divide(values.sum, values.size)

      def median
        sorted = values.sort
        mid = sorted.size / 2
        sorted.size.odd? ? sorted[mid] : divide(sorted[mid - 1] + sorted[mid], 2)
      end

      def min = values.min
      def max = values.max

      private

      # fdiv for Integers (true division into a Float); ordinary `/` for
      # BigDecimal and Float, both of which already divide truly.
      def divide(numerator, denominator)
        numerator.is_a?(Integer) ? numerator.fdiv(denominator) : numerator / denominator
      end
    end

    # Each metric: the Run reader it comes from (a method name), its column
    # label, and how to render one value. Declared once so {#distribution},
    # {#report}'s summary, and the per-run appendix all read the SAME source and
    # cannot drift.
    METRICS = {
      total_tokens: { label: "total tokens", reader: :total_tokens, fmt: ->(v) { format("%.1f", v) } },
      cache_hit_ratio: { label: "cache hit ratio", reader: :cache_hit_ratio, fmt: ->(v) { format("%.3f", v) } },
      cost: { label: "cost (USD)", reader: :cost, fmt: ->(v) { format("%.6f", v) } },
      score: { label: "grader score", reader: :score, fmt: ->(v) { format("%.2f", v) } }
    }.freeze

    # @param runs [Array<Run>] the runs to compare (n >= 2)
    # @raise [ArgumentError] on fewer than two runs
    # @raise [Capability::Guard::Mismatch] when the runs degraded different sets
    def initialize(runs)
      @runs = Array(runs).freeze
      raise ArgumentError, "compare needs at least two runs; one run is not a distribution" if @runs.size < 2

      guard_degraded!
    end

    # The capabilities every run in this comparison degraded (equal by the guard).
    def degraded = @runs.first.degraded

    # @param metric [Symbol] one of {METRICS}'s keys
    # @return [Distribution] that metric's values across the runs
    def distribution(metric)
      spec = METRICS.fetch(metric) { raise ArgumentError, "unknown metric #{metric.inspect}" }
      Distribution.new(@runs.map { |run| run.public_send(spec.fetch(:reader)) })
    end

    # A scannable report: a header, a per-metric summary table, and a per-run
    # appendix. Returned as a String -- never printed.
    #
    # @return [String]
    def report
      [header, "", summary_table, "", per_run_table].join("\n")
    end

    private

    def guard_degraded!
      @runs.map(&:degraded).each_cons(2) { |(a, b)| Capability::Guard.guard!(a, b) }
    end

    def header
      "Compare — #{@runs.size} runs, degraded: #{degraded.empty? ? "none" : degraded.to_a.join(", ")}"
    end

    # Score is only reportable when EVERY run was graded; a distribution over a
    # subset would silently compare different populations.
    def shown_metrics
      METRICS.keys.select { |key| key != :score || @runs.all?(&:graded?) }
    end

    def summary_table
      rows = shown_metrics.map do |key|
        dist = distribution(key)
        fmt = METRICS.fetch(key).fetch(:fmt)
        [METRICS.fetch(key).fetch(:label), dist.n.to_s, *[dist.mean, dist.median, dist.min, dist.max].map(&fmt)]
      end
      table(%w[metric n mean median min max], rows)
    end

    def per_run_table
      headers = ["run", *shown_metrics.map { |key| METRICS.fetch(key).fetch(:label) }]
      rows = @runs.map { |run| [run.name, *shown_metrics.map { |key| cell(key, run) }] }
      table(headers, rows)
    end

    def cell(key, run)
      spec = METRICS.fetch(key)
      spec.fetch(:fmt).call(run.public_send(spec.fetch(:reader)))
    end

    # Fixed-width table: first column left-justified (labels), the rest right-
    # justified (numbers line up on the decimal). A dashed rule under the header.
    def table(headers, rows)
      widths = column_widths(headers, rows)
      separator = widths.map { |w| "-" * w }.join("  ")
      [row_line(headers, widths), separator, *rows.map { |row| row_line(row, widths) }].join("\n")
    end

    def column_widths(headers, rows)
      headers.each_index.map { |i| ([headers[i]] + rows.map { |row| row[i] }).map(&:length).max }
    end

    def row_line(cells, widths)
      cells.each_index.map { |i| i.zero? ? cells[i].ljust(widths[i]) : cells[i].rjust(widths[i]) }.join("  ")
    end
  end
end
