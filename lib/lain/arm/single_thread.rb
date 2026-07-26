# frozen_string_literal: true

module Lain
  class Arm
    # The control arm: one linear Timeline driven through {Agent#ask}, the
    # baseline every richer topology is measured against. It runs in the shared
    # process environment, so it acquires a lease from the injected isolation
    # backend and releases it -- honoring the same lifecycle a parallel arm
    # uses -- but reads no isolated WorkerEnv off it (the default Null leases
    # nothing).
    class SingleThread < Arm
      # Monotonic wall-clock: CLOCK_MONOTONIC never jumps backward on an NTP
      # step, so an elapsed measurement is never negative. Injectable so a spec
      # can pin it deterministic.
      DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # @param name [String] the arm's label
      # @param clock [#call] returns a monotonic seconds Float; injectable
      # @param price_book [PriceBook] prices the run's journal into dollars
      # @param handoff [#reclaim] the worker-completion point: hand the work
      #   back, resolve a conflict, release. The Null releases and nothing else.
      def initialize(name: "single-thread", clock: DEFAULT_CLOCK, price_book: PriceBook.default,
                     handoff: Isolation::WorkerHandoff::Null)
        super(name:)
        @clock = clock
        @price_book = price_book
        @handoff = handoff
      end

      # Spawn one agent through `spawn_seam`, ask it the task, and hand back the
      # graded, priced, timed {Run}. The `spawn_seam` is handed a fresh recording
      # journal so this arm can price exactly the turns this run produced; the
      # grader scores the resulting Timeline.
      #
      # `elapsed` times ONLY {Agent#ask} -- the clock stops before grading and
      # pricing, which run after. So wall-time is the model/tool work under study,
      # never the harness's own scoring/accounting overhead (which would otherwise
      # make a slow grader look like a slow arm).
      #
      # @param task [String] the instruction to ask
      # @param spawn_seam [#call] `call(journal:, **spawn_opts) -> Agent`, a FRESH
      #   agent per call; this arm passes only `journal:`
      # @param grader [#grade] `grade(timeline) -> Grader::Grade`
      # @param isolation [#acquire] the injected backend (Null by default)
      # @return [Run]
      def run(task, spawn_seam:, grader:, isolation: NoIsolation)
        lease = isolation.acquire(name)
        journal = Channel.new
        agent = spawn_seam.call(journal:)
        elapsed = timed { agent.ask(task) }
        graded = graded_run(agent, grader:, elapsed:, journal:)
        @handoff.reclaim(lease, worker_id: name)
        graded
      ensure
        # `#reclaim` above is the SETTLED completion -- handback, resolver,
        # release -- and it only happens when the ask returned. `#surrender` here
        # is what stops any exception class from releasing the `--detach`ed
        # checkout without FIRST trying to anchor the worker's commits to a ref;
        # it also restores a parent left mid-merge, and it spawns NOTHING,
        # because an unbounded provider round trip inside an unwinding `ensure`
        # would hold the worktree for as long as the provider hangs. It no-ops on
        # an already-released lease, so the settled path pays one boolean. This
        # arm has no per-worker result to fold a Report into, so the Handback
        # journal is what records either.
        @handoff.surrender(lease, worker_id: name)
      end

      private

      # Grade and price the settled agent -- the accounting half of {#run}, split
      # out so the lifecycle half (lease, ask, hand back, release) reads as its
      # own concern, the same split {DualLedger} and {AdaptiveRouter} already
      # make.
      def graded_run(agent, grader:, elapsed:, journal:)
        ledger = Ledger.from_journal(journal.drain.map(&:to_journal), price_book: @price_book)
        Run.new(arm: name, timeline: agent.timeline, grade: grader.grade(agent.timeline), elapsed:, ledger:)
      end

      # Run the block, returning the monotonic seconds it took (the block's own
      # value is discarded -- the caller reads the settled Timeline off the agent).
      def timed
        started = @clock.call
        yield
        @clock.call - started
      end
    end
  end
end
