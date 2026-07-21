# frozen_string_literal: true

module Lain
  module Bench
    # PC-6, the chunk's closing deliverable: the shape x density sweep that
    # answers "which execution SHAPE, at which seam DENSITY, for this task class"
    # -- and does it against a first-class REACTIVE baseline, so plan-shaped
    # compaction has to BEAT something to claim anything.
    #
    # One fixed multi-step {Fixture} plan runs under six arms: shapes
    # ({Plan::LinearRewrite} / {Plan::ForkPerStep}) crossed with seam densities
    # (every step / author-thinned / none). At density `none` there are no plan
    # seams, so no shape action ever fires and BOTH shapes fall to the reactive
    # `cache-aware-compaction` baseline ({Compaction::Scheduler}) -- that row is
    # the reference line, identical across the two nominal shapes by construction
    # (the {Report} says so, the {ArmSweep} identical-rows precedent).
    #
    # Every arm reports grader score, a context-byte token proxy, and cache-writes
    # as DISTRIBUTIONS over the scripted runs; wall-clock reads ABSENT under mock
    # replay. The whole thing is deterministic -- fixtures in, real renders,
    # zero network -- so the report is byte-identical across runs, the guarantee
    # every sweep here gives (memoized so "report twice" is free).
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

      # The Compare-style report as a String -- never printed (output
      # discipline). Memoized, so "report twice" is byte-identical for free.
      # @return [String]
      def report = @report ||= Report.new(measurements, arms: arms.map(&:label), runs: @fixture.runs.map(&:id)).to_s

      # One {Measurement} per (arm, run), arms-major then run order. Exposed so a
      # spec can check the shape invariants numerically (fork writes zero, linear
      # rewrites at its seams), the way {ArmSweep#measurements} exposes its own.
      # @return [Array<Measurement>]
      def measurements
        @measurements ||= arms.flat_map { |arm| @fixture.runs.map { |run| measure(arm, run) } }.freeze
      end

      # The six arms: shapes x densities. A method (not a load-time constant)
      # because {Fixture::DENSITIES} loads after this class body -- the sibling
      # files require at the bottom, the ArmSweep load-order idiom.
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
# needs them before runtime (arms/measurements/report run at call time), the
# children-after-the-class-body load order arm_sweep.rb uses. Separate FILES,
# one responsibility each: Fixture loads, Driver measures, Report renders.
require_relative "plan_sweep/fixture"
require_relative "plan_sweep/driver"
require_relative "plan_sweep/report"
