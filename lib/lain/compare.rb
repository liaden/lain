# frozen_string_literal: true

require "bigdecimal"

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
    Run = Data.define(:name, :usage, :cost, :score, :degraded, :posture) do
      # @param name [String] this run's label in the comparison table (the arm
      #   it came from)
      # @param timeline [Lain::Timeline] the recorded run
      # @param ledger [Lain::Ledger] usage + cost, deduped by content-address.
      #   Required, no default: usage lives in the Journal, so only the caller
      #   knows which journal priced this run.
      # @param grade [#score, nil] a grader's verdict, if the run was graded
      # @param degraded [Capability::DegradedSet] what this run silently lost
      # @param posture [nil, Posture, Mode, Mode::Posture, Symbol] the ladder
      #   rung this run was in, however the caller holds it. nil -- the default,
      #   and what every recording made before modes existed answers -- means
      #   NOT RECORDED, which is not a rung (see {Posture}).
      def self.from_timeline(name:, timeline:, ledger:, grade: nil,
                             degraded: Capability::DegradedSet.new([]), posture: nil)
        new(name:, usage: ledger.usage(timeline), cost: ledger.cost(timeline),
            score: grade&.score, degraded:, posture:)
      end

      def initialize(name:, usage:, cost:, degraded:, score: nil, posture: nil)
        super(name: -name.to_s, usage:, cost:, score:, degraded:, posture: Posture.coerce(posture))
      end

      def total_tokens = usage.total_tokens
      def cache_hit_ratio = usage.cache_hit_ratio
      def cache_write_tokens = usage.cache_creation_input_tokens
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
      score: { label: "grader score", reader: :score, fmt: ->(v) { format("%.2f", v) } },
      cache_write_tokens: { label: "cache write tokens", reader: :cache_write_tokens,
                            fmt: ->(v) { format("%.1f", v) } }
    }.freeze

    # @param runs [Array<Run>] the runs to compare (n >= 2)
    # @raise [ArgumentError] on fewer than two runs
    # @raise [Capability::Guard::Mismatch] when the runs degraded different sets
    # @raise [Posture::Mismatch] when the runs ran under different postures
    def initialize(runs)
      @runs = Array(runs).freeze
      raise ArgumentError, "compare needs at least two runs; one run is not a distribution" if @runs.size < 2

      guard_degraded!
      guard_postures!
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

    # EVERY pair, UNLIKE the degraded guard's `each_cons` above -- and precisely
    # because that guard's reason is the opposite one. Degraded sets compare by
    # equality, which is transitive, so adjacent pairs settle the whole list.
    # Posture agreement is NOT transitive: an unrecorded posture agrees with
    # everything, so `[manual, not recorded, auto]` passes adjacent-pairwise on
    # the strength of the absence sitting between them. A spec pins that.
    def guard_postures!
      @runs.map(&:posture).combination(2) { |(a, b)| Posture.guard!(a, b) }
    end

    # Pipe-delimited, because both facts it carries are comma lists themselves:
    # `degraded: a, b, posture: c` gives a reader no way to see where one ends.
    def header
      ["Compare — #{@runs.size} runs",
       "degraded: #{degraded.empty? ? "none" : degraded.to_a.join(", ")}",
       posture_clause].join(" | ")
    end

    # The posture belongs in the HEADER rather than as a per-run column, and
    # that is a choice, not a constraint (a column appended last shifts nothing
    # a report parser reads). It sits beside `degraded:` because it is the same
    # KIND of fact -- what makes these runs comparable at all, guarded up front
    # -- and not a measurement of one run the way every appendix column is. It
    # also states one value where a column would repeat it on every row, which
    # is the whole shape of a designed sweep: an arm fixes its posture.
    #
    # One posture when every run reads the same -- including the all-unrecorded
    # case every pre-modes report is -- and otherwise one per run, named. An
    # absence is stated as an absence rather than dropped: a report that omitted
    # it would read as though the axis had been controlled for.
    def posture_clause
      labels = @runs.map { |run| run.posture.to_s }
      return "posture: #{labels.first}" if labels.uniq.size == 1

      "posture: #{@runs.map { |run| "#{run.name}=#{run.posture}" }.join(", ")}"
    end

    # Score is only reportable when EVERY run was graded; a distribution over a
    # subset would silently compare different populations.
    def shown_metrics
      METRICS.keys.select { |key| key != :score || @runs.all?(&:graded?) }
    end

    # Compare's rows are METRICS, not arms -- but the column-to-cell pairing
    # under n/mean/median/min/max is the very one {ArmFold#row} owns, so this
    # borrows the row and supplies its own first column. What is shared is the
    # pairing, not the axis: this table still folds ACROSS the runs, which is why
    # Compare is not an ArmFold (see that class's comment).
    def summary_table
      rows = shown_metrics.map { |key| stat_fold.row(key, distribution(key), fmt: METRICS.fetch(key).fetch(:fmt)) }
      Table.new(headers: ["metric", *ArmFold::HEADERS.drop(1)], rows:).to_s
    end

    # Labels each row with its metric's declared label; ArmFold does the rest.
    def stat_fold
      @stat_fold ||= ArmFold.new(label: ->(key) { METRICS.fetch(key).fetch(:label) })
    end

    def per_run_table
      headers = ["run", *shown_metrics.map { |key| METRICS.fetch(key).fetch(:label) }]
      rows = @runs.map { |run| [run.name, *shown_metrics.map { |key| cell(key, run) }] }
      Table.new(headers:, rows:).to_s
    end

    def cell(key, run)
      spec = METRICS.fetch(key)
      spec.fetch(:fmt).call(run.public_send(spec.fetch(:reader)))
    end
  end
end

# After the class body: both reopen Compare, and neither is referenced before
# runtime -- ArmFold appears only inside method bodies (#summary_table), so this
# require may sit here in either order, and either child may equally be required
# at the top. The constraint that DOES bind is in lain.rb: `lain/compare` must
# load before `lain/bench` (:64 before :65), because Bench::Sweep resolves
# Compare::ArmFold::HEADERS while evaluating its own COLUMNS constant. Swap those
# two lines and the suite dies with
# `sweep.rb: uninitialized constant Lain::Bench::Sweep::Compare`.
require_relative "compare/table"
require_relative "compare/arm_fold"
require_relative "compare/posture"
