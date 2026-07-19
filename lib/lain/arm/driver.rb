# frozen_string_literal: true

module Lain
  class Arm
    # Runs N arms over a task suite and folds each ARM's runs into its own
    # per-metric distributions -- grader score, tokens, wall-time -- laid side by
    # side as a scannable report.
    #
    # This is a Compare-STYLE report, not a {Compare}: Compare folds many runs
    # across a single axis into one distribution PER METRIC, whereas the Driver
    # folds each arm's runs into ITS OWN distributions and ranks the arms next to
    # each other ({Bench::Sweep}'s shape). So -- per this seam's escalation
    # trigger -- it does NOT reshape Compare's public surface; it reuses the two
    # pieces that fit verbatim, {Compare::Distribution} (the mean/median/min/max
    # value object) and {Compare::Table} (the aligned renderer), and renders its
    # own per-metric tables. Wall-time is a real distribution here because a
    # {Compare::Run} does not model it -- it rides on {Arm::Run} instead.
    class Driver
      # Each metric: how to pull one value off a {Run}, and how to render it. One
      # titled table per metric, rows = arms, so "distributions per arm" reads at
      # a glance and every column comes from one declared source.
      METRICS = {
        "grader score" => { of: :score, fmt: ->(value) { format("%.3f", value) } },
        "total tokens" => { of: :total_tokens, fmt: ->(value) { format("%.1f", value) } },
        "wall-time (s)" => { of: :elapsed, fmt: ->(value) { format("%.4f", value) } }
      }.freeze
      private_constant :METRICS

      COLUMNS = %w[arm n mean median min max].freeze
      private_constant :COLUMNS

      # @param arms [Array<Arm>] the topologies under comparison
      # @param tasks [Array<String>] the suite; n >= 2 so each arm's fold is a
      #   real distribution rather than a single-sample point
      # @param spawn_seam [#call] the agent/child factory threaded into every arm
      # @param grader [#grade] scores each run's Timeline
      # @param isolation [#acquire] the injected backend, threaded into every arm
      # @raise [ArgumentError] on fewer than two tasks or no arms
      def initialize(arms, tasks:, spawn_seam:, grader:, isolation: NoIsolation)
        @arms = Array(arms).freeze
        @tasks = Array(tasks).freeze
        raise ArgumentError, "the driver needs at least one arm to compare" if @arms.empty?
        raise ArgumentError, "a distribution needs n >= 2 tasks; one run is not a distribution" if @tasks.size < 2

        @spawn_seam = spawn_seam
        @grader = grader
        @isolation = isolation
      end

      # A scannable report as a String -- never printed (output discipline). One
      # titled table per metric, each row an arm's distribution over the suite.
      #
      # @return [String]
      def report
        @report ||= render(measured)
      end

      private

      # [arm_name, {metric_label => Distribution}] per arm, in the order given.
      def measured
        @arms.map { |arm| [arm.name, distributions_for(arm)] }
      end

      def distributions_for(arm)
        runs = @tasks.map { |task| arm.run(task, spawn_seam: @spawn_seam, isolation: @isolation, grader: @grader) }
        METRICS.transform_values { |spec| Compare::Distribution.new(runs.map { |run| run.public_send(spec.fetch(:of)) }) }
      end

      def render(measured_arms)
        [header, *METRICS.keys.map { |label| section(label, measured_arms) }].join("\n\n")
      end

      def header
        "Arm driver — #{@arms.size} arms over #{@tasks.size} tasks"
      end

      def section(label, measured_arms)
        fmt = METRICS.fetch(label).fetch(:fmt)
        rows = measured_arms.map do |(name, dists)|
          dist = dists.fetch(label)
          [name, dist.n.to_s, *[dist.mean, dist.median, dist.min, dist.max].map(&fmt)]
        end
        "#{label}\n#{Compare::Table.new(headers: COLUMNS, rows:)}"
      end
    end
  end
end
