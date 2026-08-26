# frozen_string_literal: true

module Lain
  # An orchestration TOPOLOGY made swappable and bench-scorable. Every arm answers
  # the same question -- "run this task and hand back a graded trajectory" -- in
  # the same shape (`#run -> Run`), so a {Driver} can score them against each other
  # and the single-thread control is the arm every richer topology has to beat.
  #
  # The seam is deliberately minimal. A synthesis hook, a Task/Progress ledger, a
  # spawn-time router are ONE topology's needs and live on THAT concrete arm: the
  # {Tool::SpawnPolicy} altitude mistake this seam exists to avoid is a base that
  # grows every child's knobs and stops being a seam. What the base does own is the
  # lease LIFECYCLE ({#leased}), because acquire/reclaim/surrender is identical
  # across topologies and getting it wrong destroys a worker's commits. What an arm
  # MEASURES is injected rather than inherited -- see {Instrument}.
  class Arm
    # A LOCAL null rather than a reference into the Isolation unit, so this file
    # depends on no constant it cannot resolve. The single-thread control runs in
    # the shared process environment and never needs an isolated worktree.
    module NoIsolation
      # A lease that owns no isolated resource: `worker_env` is nil, meaning "the
      # shared process environment, unchanged".
      class Lease
        def release = nil
        def worker_env = nil

        # Always false, truthfully: this lease is shared, frozen and holds
        # nothing, so it is never "given up". It completes the
        # {Isolation::Lease} duck `Isolation::WorkerHandoff` guards on to stay
        # exactly-once across its reclaim/surrender pair.
        def released? = false
      end

      LEASE = Lease.new.freeze

      # @return [Lease] the shared no-op lease
      def self.acquire(_worker_id = nil) = LEASE
    end

    # A graded trajectory, and the Arm seam's whole output vocabulary. A RESULT
    # CARRIER, not a value object: frozen (Data), but it holds a live {Timeline}
    # over a mutable {Store}, so unlike {Compare::Run} it is deliberately NOT
    # `Ractor.shareable?` -- there is no shareability spec to satisfy here and
    # porting one on would be a category error. Wall-time rides along because
    # {Compare} does not model it.
    #
    # REACHABILITY CONTRACT (load-bearing for fan-out arms). `#usage`/`#cost`/
    # `#compare_run` fold the Ledger over the unique turns REACHABLE from
    # `timeline`'s head, and {Ledger} walks RENDER ancestry only (first-parent,
    # {Timeline#ancestors}) -- causal edges are NOT priced. So an arm's totals are
    # made correct one of two ways: (a) every paid turn sits on the head's
    # first-parent chain, which a single-thread run gets for free; or (b) a paid
    # turn that is not render-reachable (a fan-out worker's fresh-root turns) has
    # its usage re-keyed onto a reachable digest, each moved record marked
    # `reattributed: true` and `attributed_from: <the worker head>` so per-worker
    # spend stays recoverable. Fan-out synthesis is (b): the multi-parent {Event}
    # it commits names every worker head causally, while the workers' tokens
    # re-attribute onto the reachable synthesis turn. Returning a Run whose totals
    # silently omit a paid worker prices that worker at zero.
    Run = Data.define(:arm, :timeline, :grade, :elapsed, :ledger) do
      # @return [Compare::Run] this trajectory priced and graded, in Compare's
      #   vocabulary
      def compare_run
        Compare::Run.from_timeline(name: arm, timeline:, ledger:, grade:)
      end

      # No model needed, so a tokens metric is available even where a bare-mock
      # run cannot be priced.
      def usage = ledger.usage(timeline)
      def total_tokens = usage.total_tokens

      # Each payment priced by ITS OWN recorded model, and deliberately not as
      # forgiving as {#usage}: {Ledger#cost_of} raises {PriceBook::UnknownModel}
      # both for a payment that recorded no model and for one naming a model the
      # book has no row for, and this lets that through. Rescuing to zero would
      # report an unpriceable arm as FREE -- on a bench whose headline metric is
      # cost, silence is the failure mode.
      #
      # One frame out the answer inverts: a report folding this metric must not
      # die of it, or an unpriceable model takes score, tokens and wall-time down
      # with it after every run was already paid for. {Driver#fold} degrades the
      # cost SECTION to this error's own message instead. The escape is a
      # {PriceBook} built with a `fallback:`, handed to this arm's {Instrument} --
      # injectable by a library caller and by nothing on the command line, which
      # is why the Driver's degradation had to exist.
      #
      # @return [BigDecimal]
      # @raise [PriceBook::UnknownModel] on a payment whose model the book
      #   cannot price and with no fallback configured
      def cost = ledger.cost(timeline)

      # @return [Float] the grader's 0.0..1.0 score
      def score = grade.score
    end

    # `handoff:` lives here and not on a child because {#leased} -- the base's own
    # lease bracket -- is its only caller. That is the seam's own lifecycle, a
    # different claim from "every child's knobs".
    #
    # @param name [String] what this arm is, in reports and Compare::Run names
    # @param handoff [#reclaim, #surrender] the worker-completion point: hand the
    #   work back, resolve a conflict, release. The Null releases and nothing else.
    def initialize(name:, handoff: Isolation::WorkerHandoff::Null)
      @name = -name.to_s
      @handoff = handoff
    end

    attr_reader :name

    # Splatted BECAUSE it is abstract. The keywords are the contract --
    # `spawn_seam:` is the agent/child factory the topology drives, `isolation:`
    # the injected backend a parallel arm leases per worker (the control ignores
    # it), `grader:` scores the resulting Timeline -- and a concrete arm
    # re-declares them, so a subclass that forgets fails loudly rather than
    # silently no-oping.
    #
    # The `spawn_seam` duck is `call(journal:, **spawn_opts) -> Agent`, returning
    # a FRESH agent per call (Provider::Mock and any real provider are stateful).
    # The `**spawn_opts` tail is the widening a spawn-time router needs: an
    # adaptive router passes `model:`/sibling-template at the spawn boundary and a
    # parametrized child workspace needs its own keys, which a fixed-arity
    # `->(journal:) {}` would reject.
    #
    # @return [Run]
    def run(*, **)
      raise NotImplementedError,
            "#{self.class} must implement #run(task, spawn_seam:, isolation:, grader:) -> Arm::Run"
    end

    private

    # The lease bracket, written ONCE, returning whatever the block returned so
    # each arm still assembles its own {Run}.
    #
    # `#reclaim` is the SETTLED completion (handback, resolver, release) and runs
    # only when the block returned. `#surrender` in the `ensure` is what stops any
    # exception class from releasing a `--detach`ed checkout without FIRST trying
    # to anchor the worker's commits to a ref; `Async::Cancel` and `Interrupt` are
    # `< Exception` and reach no rescue, which is exactly why the attempt lives in
    # an `ensure`. It spawns NOTHING, because an unbounded provider round trip
    # inside an unwinding `ensure` would hold the worktree for as long as the
    # provider hangs. Both no-op on an already-released lease.
    #
    # This is the WHOLE-RUN bracket; {OrchestratorWorker} leases per WORKER and
    # keeps its own over the same `@handoff`.
    #
    # @param isolation [#acquire] the injected backend
    # @return [Object] the block's own value
    def leased(isolation:)
      lease = isolation.acquire(name)
      result = yield lease
      @handoff.reclaim(lease, worker_id: name)
      result
    ensure
      @handoff.surrender(lease, worker_id: name)
    end
  end
end

# After the class body: the concrete arms and the driver reference Arm and
# Arm::Run, so they load once the class exists.
require_relative "arm/instrument"
require_relative "arm/ledger_state"
require_relative "arm/single_thread"
require_relative "arm/adaptive_router"
require_relative "arm/dual_ledger"
require_relative "arm/synthesis"
require_relative "arm/orchestrator_worker"
require_relative "arm/driver"
