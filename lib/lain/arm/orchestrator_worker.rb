# frozen_string_literal: true

require "async"

module Lain
  class Arm
    # The orchestrator-worker topology: a lead decomposes a task into N
    # independent subtasks, fans workers out over ONE shared, Monitor-guarded
    # Store (so parallel commits neither race nor reorder), then a {Synthesis}
    # turn folds their results into a single multi-parent causal Event -- the
    # first any arm writes. Measured against the {SingleThread} control the same
    # way every richer topology is: same `#run -> Run` shape, same graded,
    # priced, timed trajectory.
    #
    # Each worker gets a FRESH Timeline root in the shared Store (CLAUDE.md:
    # subagents never inherit the parent's prompt) and its own leased WorkerEnv
    # from the injected isolation backend, so the arm theme and the isolation
    # theme stay decoupled -- the default {NoIsolation} leases nothing and the
    # arm runs in the shared process environment unchanged.
    class OrchestratorWorker < Arm
      # The default decomposition: one subtask per non-empty line, or the whole
      # task when it has no line structure. Injectable so a bench can decompose
      # by any policy (a real lead would decompose with a model call; the bench
      # arm keeps it deterministic).
      DEFAULT_DECOMPOSE = lambda do |task|
        lines = task.to_s.lines.map(&:strip).reject(&:empty?)
        lines.empty? ? [task.to_s] : lines
      end

      # @param name [String] the arm's label
      # @param decompose [#call] `call(task) -> Array<String>` subtasks
      # @param synthesis [Synthesis] the fan-in fold
      # @param clock [#call] monotonic seconds, injectable for deterministic specs
      # @param price_book [PriceBook] prices the run's journal into dollars
      def initialize(name: "orchestrator-worker", decompose: DEFAULT_DECOMPOSE,
                     synthesis: Synthesis.new, clock: SingleThread::DEFAULT_CLOCK,
                     price_book: PriceBook.default)
        super(name:)
        @decompose = decompose
        @synthesis = synthesis
        @clock = clock
        @price_book = price_book
      end

      # Decompose, fan the workers out, fold their results, and hand back the
      # graded, priced, timed {Run}. `elapsed` times ONLY the fan-out (the
      # model/tool work under study) -- decomposition, synthesis, grading, and
      # pricing are harness accounting and run outside the clock, the same
      # discipline {SingleThread} follows.
      #
      # @param task [String] the instruction to decompose and orchestrate
      # @param spawn_seam [#call] `call(journal:, **spawn_opts) -> Agent`, a FRESH
      #   worker agent per call; this arm passes `base_timeline:` (the fresh root
      #   in the shared Store), `worker_env:` (the lease's env), and `spawned_from:`
      # @param grader [#grade] `grade(timeline) -> Grader::Grade`
      # @param isolation [#acquire] the injected backend (Null by default)
      # @return [Run]
      def run(task, spawn_seam:, grader:, isolation: NoIsolation)
        lead = Timeline.empty(store: Store.new)
                       .commit(role: :user, content: [{ "type" => "text", "text" => task }])
        results = nil
        elapsed = timed { results = fan_out(@decompose.call(task), spawn_seam:, isolation:, lead:) }
        folded = @synthesis.fold(lead, results)
        ledger = Ledger.from_journal(folded.ledger_entries, price_book: @price_book)
        Run.new(arm: name, timeline: folded.timeline, grade: grader.grade(folded.timeline), elapsed:, ledger:)
      end

      private

      # Workers run concurrently over the one shared Store; order is preserved so
      # the synthesis folds subtasks deterministically. Under Provider::Mock the
      # tasks settle synchronously, but the shape is the real fan-out (5-1.4).
      def fan_out(subtasks, spawn_seam:, isolation:, lead:)
        Sync do
          subtasks.each_with_index
                  .map { |subtask, index| Async { work(subtask, index, spawn_seam:, isolation:, lead:) } }
                  .map(&:wait)
        end
      end

      # One worker's isolation lifecycle: lease its WorkerEnv, run it under the
      # lease, and release the lease whatever happens. The lease is this method's
      # whole responsibility; {#settle} owns the spawn and the outcome.
      def work(subtask, index, spawn_seam:, isolation:, lead:)
        lease = isolation.acquire("#{name}-worker-#{index}")
        settle(subtask, spawn_seam:, lease:, lead:)
      ensure
        lease&.release
      end

      # Spawn a fresh agent rooted in the shared Store, ask its subtask, and
      # carry back the settled head plus the spend it journaled. A worker failure
      # is CAUGHT and returned as a named {Result} (its error kept, any partial
      # spend preserved) -- the escalation trigger's "a failed worker is a named
      # input, not an omission".
      def settle(subtask, spawn_seam:, lease:, lead:)
        journal = Channel.new
        agent = spawn_seam.call(journal:, base_timeline: Timeline.empty(store: lead.store),
                                worker_env: lease.worker_env, spawned_from: lead.head_digest)
        response = agent.ask(subtask)
        Synthesis::Result.ok(head_digest: agent.timeline.head_digest, text: response.text,
                             usage_records: drain(journal))
      rescue StandardError => e
        Synthesis::Result.failed(error: e.message, usage_records: drain(journal))
      end

      # `journal` is bound before any spawn can raise (settle's first line), so
      # both the ok and rescue paths always have it -- no nil-guard.
      def drain(journal) = journal.drain.map(&:to_journal)

      # Run the block, returning the monotonic seconds it took.
      def timed
        started = @clock.call
        yield
        @clock.call - started
      end
    end
  end
end
