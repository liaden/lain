# frozen_string_literal: true

module Lain
  module Bench
    # The shape x density sweep: which execution SHAPE, at which seam DENSITY,
    # for this task class -- measured against a first-class REACTIVE baseline,
    # so plan-shaped compaction has to BEAT something to claim anything.
    #
    # One fixed multi-step {Fixture} plan runs under six arms: shapes
    # ({Plan::LinearRewrite} / {Plan::ForkPerStep}) crossed with seam densities
    # (every step / author-thinned / none). At density `none` there are no plan
    # seams, so no shape action fires and BOTH shapes fall to the reactive
    # {Compaction::Scheduler} baseline -- that row is the reference line,
    # identical across the two nominal shapes by construction.
    #
    # Every arm reports grader score, a context-byte token proxy and
    # cache-writes as DISTRIBUTIONS over the scripted runs; wall-clock reads
    # ABSENT under mock replay. Fixtures in, real renders, zero network, so the
    # report is byte-identical across runs.
    class PlanSweep
      # One (arm, run) measured cell. `arm` is the arm's label; the three numbers
      # are what the {Report} folds into per-arm distributions.
      Measurement = Data.define(:arm, :run_id, :score, :tokens, :cache_writes)

      # One arm: an execution shape crossed with a seam density.
      Arm = Data.define(:shape, :density) do
        def label = "#{shape} / #{density}"
      end

      # @param plan_path [String] the committed plan markdown
      # @param runs_path [String] the committed scripted-runs YAML
      def initialize(plan_path:, runs_path:)
        @fixture = Fixture.new(plan_path:, runs_path:)
        @driver = Driver.new(fixture: @fixture)
      end

      # Memoized, so that reporting twice is byte-identical for free.
      # @return [String]
      def report = @report ||= Report.new(measurements, arms: arms.map(&:label), runs: @fixture.runs.map(&:id)).to_s

      # One {Measurement} per (arm, run), arms-major then run order. Exposed so
      # a spec can check the shape invariants numerically: fork writes zero,
      # linear rewrites at its seams.
      # @return [Array<Measurement>]
      def measurements
        @measurements ||= arms.flat_map { |arm| @fixture.runs.map { |run| measure(arm, run) } }.freeze
      end

      # A method rather than a load-time constant, because {Fixture::DENSITIES}
      # loads after this class body.
      def arms
        @arms ||= %i[linear fork].flat_map { |shape| Fixture::DENSITIES.map { |density| Arm.new(shape:, density:) } }
                                 .freeze
      end

      private

      def measure(arm, run)
        score, tokens, cache_writes = @driver.measure(shape: arm.shape, density: arm.density, run:)
        Measurement.new(arm: arm.label, run_id: run.id, score:, tokens:, cache_writes:)
      end
    end
  end
end

# After the class body: the sibling units reopen PlanSweep and nothing above
# needs them before runtime. Separate FILES, one responsibility each: Fixture
# loads, Driver measures, Report renders.
