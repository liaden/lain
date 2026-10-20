# frozen_string_literal: true

require "bigdecimal"

module Lain
  # Compares n>=2 runs by DISTRIBUTION, because a single A/B is noise: one run
  # each of two arms tells you nothing about whether the difference you see is
  # the tactic or the variance. So Compare folds each metric -- {METRICS} names
  # all 8 -- into a distribution across the runs and reports mean/median/min/max.
  #
  # It also REFUSES, up front, on the two axes that decide whether these runs
  # were comparable at all. {Capability::DegradedSet}: if one arm silently lost
  # `:thinking` and the other kept it, half the tactic under study never ran on
  # that arm and the comparison measures the missing capability, not the
  # variable. {Mode}, the mode axis: an `auto` run never stopped for a human,
  # so a distribution across it and an `ask` run measures the approval level.
  # Both raise rather than report -- a lie you can read is worse than an error
  # you cannot ignore.
  #
  # Both arrive as arguments a caller must thread, and a caller that forgets
  # one gets a vacuous pass rather than a failure. {Bench::Variance} reads both
  # off each recording's own journal ({Bench::Session::Recording}) for exactly
  # that reason.
  #
  # What it does NOT refuse is a metric some run cannot honestly answer. That
  # metric is WITHHELD -- dropped from both tables, with a line saying why --
  # and every other metric still reports: a run the price book cannot price
  # still counted its tokens.
  #
  # The report is a DX artifact, not a debug dump: a scannable per-metric table,
  # returned as a String (nothing here touches stdout).
  class Compare
    include Declarative

    # Why a cache hit ratio over these runs would be a zero nobody measured.
    NO_PROMPT_CACHE = "not measured — every run records prompt_caching degraded, so there was no cache to hit"
    private_constant :NO_PROMPT_CACHE

    NO_COMPACTION = "not measured; no run compacted"
    private_constant :NO_COMPACTION

    UNPRICED_COMPACTION = "not measured; a run's compaction could not be priced"
    private_constant :UNPRICED_COMPACTION

    NO_CACHE_WRITES = "not measured; no run recorded a cache write"
    private_constant :NO_CACHE_WRITES

    # One run's measured outcome, in the vocabulary Compare aggregates. Built
    # either directly from measured metrics or, more usually, from a recorded
    # Timeline via {.from_timeline}, which prices it through the {Ledger}.
    #
    # `price` is {Cost::Priced} or {Cost::Unpriced}, never a bare number, so a run the book
    # cannot price is still a run: the refusal travels with it to the report
    # instead of unwinding the whole comparison from its constructor.
    Run = Data.define(:name, :usage, :price, :score, :degraded, :mode, :compaction) do
      # @param name [String] this run's label in the comparison table (the arm
      #   it came from)
      # @param timeline [Lain::Ext::Timeline] the recorded run
      # @param ledger [Lain::Ledger] usage + cost, deduped by content-address.
      #   Required, no default: usage lives in the Journal, so only the caller
      #   knows which journal priced this run.
      # @param grade [#score, nil] a grader's verdict, if the run was graded
      # @param degraded [Capability::DegradedSet] what this run silently lost
      # @param compaction [CompactionTally] what the run's journal says about compaction; the default
      #   is for a caller with no journal, as {Arm::Run#to_compare} has none
      # @param mode [nil, Compare::Mode, Lain::Mode, String] the mode trajectory this run
      #   walked, however the caller holds it. nil -- the default, and what a
      #   session that never switched answers -- means NOT RECORDED, which is
      #   not a point on the axis (see {Compare::Mode}).
      def self.from_timeline(name:, timeline:, ledger:, grade: nil,
                             degraded: Capability::DegradedSet.new([]), mode: nil, compaction: CompactionTally::NONE)
        new(name:, usage: ledger.usage(timeline), price: price_of(ledger, timeline),
            score: grade&.score, degraded:, mode:, compaction:)
      end

      # The Ledger keeps raising on a model its book has no row for; this is the
      # one place that refusal becomes a value rather than an unwound report.
      def self.price_of(ledger, timeline)
        Cost::Priced.new(amount: ledger.cost(timeline))
      rescue PriceBook::UnknownModel => e
        Cost::Unpriced.new(reason: e.message)
      end
      private_class_method :price_of

      def initialize(name:, usage:, price:, degraded:, score: nil, mode: nil, compaction: CompactionTally::NONE)
        super(name: -name.to_s, usage:, price:, score:, degraded:, mode: Mode.coerce(mode), compaction:)
      end

      # @return [BigDecimal]
      # @raise [PriceBook::UnknownModel] when this run is {Cost::Unpriced}
      def cost = price.amount

      def total_tokens = usage.total_tokens
      def cache_hit_ratio = usage.cache_hit_ratio
      def cache_write_tokens = usage.cache_creation_input_tokens
      def graded? = !score.nil?
      def summary_misses = compaction.summary_misses
      def prepared_unapplied = compaction.unapplied
      def compaction_cost_delta = compaction.cost_delta
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
                            fmt: ->(v) { format("%.1f", v) } },
      summary_misses: { label: "summary misses", reader: :summary_misses, fmt: ->(v) { format("%.1f", v) } },
      prepared_unapplied: { label: "prepared unapplied", reader: :prepared_unapplied,
                            fmt: ->(v) { format("%.1f", v) } },
      compaction_cost_delta: { label: "compaction cost delta", reader: :compaction_cost_delta,
                               fmt: ->(v) { v.is_a?(Cost::Priced) ? format("%.6f", v.amount) : v.to_s } }
    }.freeze

    # A comparison is a DISTRIBUTION, and one sample is not one. Declared over
    # the coerced list rather than the constructor's argument, because `Array()`
    # is what turns a lone Run into a list of one -- the count only means
    # anything once that has happened.
    declare do
      attribute :runs
      validates :runs, length: { minimum: 2,
                                 message: "must hold at least two; one run is not a distribution" }
    end

    # @param runs [Array<Run>] the runs to compare (n >= 2)
    # @raise [ArgumentError] on fewer than two runs
    # @raise [Capability::Guard::Mismatch] when the runs degraded different sets
    # @raise [Error] when the runs ran under different modes
    def initialize(runs)
      @runs = Array(runs).freeze
      self.class.check!(runs: @runs)

      guard_degraded!
      guard_modes!
    end

    # The capabilities every run in this comparison degraded (equal by the guard).
    def degraded = @runs.first.degraded

    # @param metric [Symbol] one of {METRICS}'s keys
    # @return [Distribution] that metric's values across the runs
    def distribution(metric)
      spec = METRICS.fetch(metric) { raise ArgumentError, "unknown metric #{metric.inspect}" }
      Distribution.new(@runs.flat_map { |run| Array(run.public_send(spec.fetch(:reader))) })
    end

    # A scannable report: a header, a per-metric summary table, and a per-run
    # appendix. Returned as a String -- never printed.
    #
    # @return [String]
    def report
      [header, "", summary_table, *withheld_lines, "", per_run_table].join("\n")
    end

    private

    def guard_degraded!
      @runs.map(&:degraded).each_cons(2) { |(a, b)| Capability::Guard.guard!(a, b) }
    end

    # EVERY pair, UNLIKE the degraded guard's `each_cons` above -- and precisely
    # because that guard's reason is the opposite one. Degraded sets compare by
    # equality, which is transitive, so adjacent pairs settle the whole list.
    # Mode agreement is NOT transitive: an unrecorded mode agrees with
    # everything, so `[checkout/ask, not recorded, checkout/auto]` passes
    # adjacent-pairwise on the strength of the absence sitting between them. A
    # spec pins that.
    def guard_modes!
      @runs.map(&:mode).combination(2) { |(a, b)| Mode.guard!(a, b) }
    end

    # Pipe-delimited, because both facts it carries are comma lists themselves:
    # `degraded: a, b, mode: c` gives a reader no way to see where one ends.
    def header
      ["Compare — #{@runs.size} runs",
       "degraded: #{degraded.empty? ? "none" : degraded.to_a.join(", ")}",
       mode_clause].join(" | ")
    end

    # In the HEADER beside `degraded:` rather than as a per-run column, because
    # it is the same KIND of fact -- what makes these runs comparable at all --
    # and not a measurement of one run the way every appendix column is.
    #
    # An absence is stated as an absence rather than dropped: a report that
    # omitted it would read as though the axis had been controlled for.
    def mode_clause
      labels = @runs.map { |run| run.mode.to_s }
      return "mode: #{labels.first}" if labels.uniq.size == 1

      "mode: #{@runs.map { |run| "#{run.name}=#{run.mode}" }.join(", ")}"
    end

    # Score is only reportable when EVERY run was graded; a distribution over a
    # subset would silently compare different populations. It is dropped
    # without a line, unlike {#withheld}, because an ungraded run is an
    # experiment that asked no grader rather than a measurement that failed.
    def shown_metrics
      METRICS.keys.select { |key| key != :score || @runs.all?(&:graded?) } - withheld.keys
    end

    # Each metric some run cannot honestly answer, with the reason. Cost goes
    # when ANY run is unpriced, for the same population reason as score. The
    # cache ratio goes on the degraded set, which the guard has already made
    # equal across the runs, so one run's answer is every run's.
    def withheld
      @withheld ||= { cost: unpriced_reason, cache_hit_ratio: no_prompt_cache_reason,
                      compaction_cost_delta: unquoted_compaction_reason,
                      cache_write_tokens: no_cache_writes_reason }.compact
    end

    def unpriced_reason
      unpriced = @runs.map(&:price).select(&:refuses?)
      Cost::Unpriced.describe(unpriced) unless unpriced.empty?
    end

    def unquoted_compaction_reason
      deltas = @runs.map(&:compaction_cost_delta)
      return UNPRICED_COMPACTION if deltas.any?(&:refuses?)

      NO_COMPACTION if deltas.all?(Cost::NONE)
    end

    # Usage reads an absent cache field as 0, so an all-zero column cannot be told from one never measured.
    def no_cache_writes_reason = (NO_CACHE_WRITES if @runs.all? { |run| run.cache_write_tokens.zero? })

    def no_prompt_cache_reason = (NO_PROMPT_CACHE if degraded.include?(:prompt_caching))

    def withheld_lines
      withheld.map { |key, reason| "#{METRICS.fetch(key).fetch(:label)}: #{reason}" }
    end

    # Compare's rows are METRICS, not arms, but the column-to-cell pairing under
    # n/mean/median/min/max is {ArmFold#row}'s. What is shared is the pairing,
    # not the axis: this table still folds ACROSS the runs, which is why Compare
    # is not an ArmFold.
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
