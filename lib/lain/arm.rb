# frozen_string_literal: true

module Lain
  # An orchestration TOPOLOGY made swappable and bench-scorable: single-thread
  # control, orchestrator-worker+synthesis, dual-ledger, adaptive-router. Every
  # arm answers the SAME question -- "run this task and hand back a graded
  # trajectory" -- in the SAME shape (`#run -> Run`), so a {Driver} can score them
  # against each other and the single-thread control is simply the arm every
  # richer topology has to beat.
  #
  # The seam is deliberately minimal: `#run(task, spawn_seam:, isolation:,
  # grader:) -> Run`, nothing more. A synthesis hook, a Task/Progress ledger, a
  # spawn-time router -- those are ONE topology's needs and live on THAT concrete
  # arm, never on this base. That is the {Tool::SpawnPolicy} altitude mistake this
  # seam exists to avoid: a base that grows every child's knobs stops being a seam.
  class Arm
    # The default isolation backend. The real seam is a later card
    # (`Isolation#acquire(worker_id) -> a Lease carrying a WorkerEnv + #release`);
    # the single-thread control runs in the shared process environment and never
    # needs an isolated worktree, so the base default is a LOCAL null that leases
    # nothing -- no dependency on the not-yet-built Isolation unit, and no
    # constant this file cannot resolve.
    module NoIsolation
      # A lease that owns no isolated resource: releasing it is a no-op and its
      # `worker_env` is nil, meaning "the shared process environment, unchanged".
      class Lease
        def release = nil
        def worker_env = nil
      end

      LEASE = Lease.new.freeze

      # @return [Lease] the shared no-op lease
      def self.acquire(_worker_id = nil) = LEASE
    end

    # A graded trajectory: the arm that produced it, the recorded Timeline, the
    # grader's {Grader::Grade}, the wall-clock seconds it took, and the
    # journal-sourced {Ledger} that prices it. This is the Arm seam's whole output
    # vocabulary. A RESULT CARRIER, not a value object: it is frozen (Data), but
    # it holds a live {Timeline} over a mutable {Store}, so unlike {Compare::Run}
    # it is deliberately NOT `Ractor.shareable?` -- there is no shareability spec
    # to satisfy, and porting one on would be a category error.
    #
    # `#compare_run` is the single AC of the seam: an arm's Run is scored by
    # {Compare::Run.from_timeline}, folding usage and cost off the recorded
    # Timeline through that run's own Ledger and carrying the grade -- nothing
    # arm-specific. Wall-time (which {Compare} does not model) rides here so the
    # {Driver} can report it alongside the metrics Compare does fold.
    #
    # REACHABILITY CONTRACT (load-bearing for fan-out arms). `#usage`/`#cost`/
    # `#compare_run` fold the Ledger over the UNIQUE turns REACHABLE from
    # `timeline`'s head, and {Ledger} walks RENDER ancestry only (first-parent,
    # {Timeline#ancestors}) -- causal edges are NOT priced. So the arm's TOTALS
    # must be made correct one of two ways. (a) RENDER-REACHABILITY: every paid
    # turn sits on the returned head's first-parent chain, which a single-thread
    # run gets for free (one linear head reaches the whole run). (b) LABELED
    # RE-ATTRIBUTION: a paid turn that is NOT render-reachable (a fan-out worker's
    # fresh-root turns) has its usage re-keyed onto a reachable digest, each moved
    # record marked `reattributed: true` and `attributed_from: <the worker head>`
    # so the record stays honest and per-worker spend is recoverable. B8's
    # synthesis is (b): the multi-parent {Event} it commits NAMES every worker
    # head causally (`commit(causal_parents:)`), while the workers' tokens
    # re-attribute onto the reachable synthesis turn. Returning a Run whose totals
    # silently omit a paid worker -- neither reachable nor re-attributed -- prices
    # that worker at zero. `arm_spec` pins that unreachable turns are not priced.
    Run = Data.define(:arm, :timeline, :grade, :elapsed, :ledger) do
      # @return [Compare::Run] this trajectory priced and graded, in Compare's
      #   vocabulary
      def compare_run
        Compare::Run.from_timeline(name: arm, timeline:, ledger:, grade:)
      end

      # Usage over the recorded Timeline's unique turns -- no model needed, so a
      # tokens metric is available even where a bare-mock run cannot be priced.
      def usage = ledger.usage(timeline)
      def total_tokens = usage.total_tokens

      # @return [Float] the grader's 0.0..1.0 score
      def score = grade.score
    end

    # @param name [String] what this arm is, in reports and Compare::Run names
    def initialize(name:)
      @name = -name.to_s
    end

    attr_reader :name

    # The strategy seam every arm implements: run `task` and hand back a graded
    # {Run}. The keywords are the whole contract -- `spawn_seam:` is the
    # agent/child factory the topology drives, `isolation:` the injected backend a
    # parallel arm leases per worker (the control ignores it), `grader:` scores the
    # resulting Timeline. Splatted here BECAUSE it is abstract: the names and their
    # meaning are the documented contract above, and a concrete arm re-declares
    # them; a subclass that forgets fails loudly rather than silently no-oping.
    #
    # The `spawn_seam` duck is `call(journal:, **spawn_opts) -> Agent`, returning
    # a FRESH agent per call (Provider::Mock and any real provider are stateful).
    # `journal:` is the recording channel the arm injects so it can price exactly
    # the turns this run produced. The `**spawn_opts` tail is the widening a
    # spawn-time router needs: {SingleThread} calls only `call(journal:)`, but
    # B10's adaptive router passes `model:`/sibling-template at the spawn boundary
    # and B11 parametrizes the child workspace -- a fixed-arity `->(journal:) {}`
    # would reject those, so the documented duck accepts the tail and a seam
    # closes over what it does not use.
    #
    # @return [Run]
    def run(*, **)
      raise NotImplementedError,
            "#{self.class} must implement #run(task, spawn_seam:, isolation:, grader:) -> Arm::Run"
    end
  end
end

# After the class body: the concrete arm and the driver both reference Arm and
# Arm::Run, so they load once the class exists (the children-after-the-class-body
# order effect/handler.rb uses).
require_relative "arm/ledger_state"
require_relative "arm/single_thread"
require_relative "arm/adaptive_router"
require_relative "arm/dual_ledger"
require_relative "arm/synthesis"
require_relative "arm/orchestrator_worker"
require_relative "arm/driver"
