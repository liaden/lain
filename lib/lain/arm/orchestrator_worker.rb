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
      # @param instrument [Instrument] times the fan-out and prices the workers'
      #   merged journals -- the same measuring collaborator every arm is
      #   injected with
      # @param handoff [#reclaim] what a finished worker's completion point does
      #   with its lease -- hand the work back, resolve a conflict, release. The
      #   Null releases and nothing else, so an unwired arm is unchanged.
      def initialize(name: "orchestrator-worker", decompose: DEFAULT_DECOMPOSE,
                     synthesis: Synthesis.new, instrument: Instrument.new,
                     handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @decompose = decompose
        @synthesis = synthesis
        @instrument = instrument
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
        elapsed, results = @instrument.timed { fan_out(@decompose.call(task), spawn_seam:, isolation:, lead:) }
        folded = @synthesis.fold(lead, results)
        # Priced as its own statement before grading, matching the other arms.
        # `#price_records` folds records the workers already drained, so nothing
        # here depends on the order -- reading the same way everywhere is the
        # point, since the three arms that DO drain cannot afford to differ.
        ledger = @instrument.price_records(folded.ledger_entries)
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
      #
      # NOT the base's {Arm#leased}, and deliberately so: that bracket is the
      # WHOLE-RUN one, keyed on the arm's name and discarding the reclaim's
      # Report. This one leases per WORKER and FOLDS that Report into the
      # worker's own result, so making the base serve both would mean a
      # result-shaping hook out there -- the one thing `arm.rb`'s seam comment
      # rules out. Same `@handoff`, two honest brackets.
      #
      # `#reclaim` runs in the BODY, not the ensure, because its
      # {Isolation::WorkerHandoff::Report} is folded into the worker's result --
      # and it can, because {#settle} catches its own failures.
      #
      # `#surrender` in the `ensure` is what makes that safe. `settle` catches
      # only `StandardError`, and this whole method runs inside an `Async` task:
      # a sibling's failure cancels it with `Async::Cancel`, which is `<
      # Exception` and reaches neither rescue. Releasing a `--detach`ed worktree
      # DESTROYS unanchored commits, so no path may release without first TRYING
      # to anchor -- `surrender` hands back, restores the parent, and releases,
      # spawning nothing (there is no budget for a model call inside an unwind).
      # Both no-op on an already-released lease, so the settled path pays one
      # boolean. What that buys is the attempt, not a guarantee the ref exists:
      # see {Isolation::WorkerHandoff}'s class doc for the case it cannot cover.
      def work(subtask, index, spawn_seam:, isolation:, lead:)
        worker_id = "#{name}-worker-#{index}"
        lease = isolation.acquire(worker_id)
        # Two named locals, in the order they must happen: the worker settles
        # first, THEN its still-live lease is handed back. Packed as arguments
        # this read as one expression whose correctness rested on Ruby's
        # left-to-right argument evaluation.
        result = settle(subtask, spawn_seam:, lease:, lead:)
        report = @handoff.reclaim(lease, worker_id:)
        handed(result, report)
      ensure
        @handoff.surrender(lease, worker_id:)
      end

      # Carry what the handoff did back on the worker's own {Synthesis::Result},
      # so a resolved conflict names its files and one that STANDS names the ref
      # still holding the work -- in the synthesis the orchestrator folds, never
      # as a conflict transcript in its context. A failed worker's message is its
      # `error`, so the summary joins THAT rather than a `text` nothing renders.
      def handed(result, report)
        return result if report.summary.empty?
        return result.with(error: joined(result.error, report.summary)) if result.failed?

        result.with(text: joined(result.text, report.summary))
      end

      def joined(existing, summary) = [existing, summary].compact.reject(&:empty?).join("\n\n")

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
    end
  end
end
