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
      # @param name [String] the arm's label
      # @param instrument [Instrument] times the ask and prices the journal
      # @param handoff [#reclaim] the worker-completion point, threaded to the
      #   base's own lease bracket
      def initialize(name: "single-thread", instrument: Instrument.new,
                     handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @instrument = instrument
      end

      # Spawn one agent through `spawn_seam`, ask it the task, and hand back the
      # graded, priced, timed {Run}. It is handed a fresh recording journal so
      # this arm prices exactly the turns this run produced.
      #
      # `elapsed` times ONLY {Agent#ask}: the clock stops before grading and
      # pricing, so wall-time is the model/tool work under study and never the
      # harness's own accounting overhead, which would make a slow grader look
      # like a slow arm.
      #
      # This arm has no per-worker result to fold an
      # {Isolation::WorkerHandoff::Report} into, so the Handback journal is what
      # records what the completion did.
      #
      # @param task [String] the instruction to ask
      # @param spawn_seam [#call] `call(journal:, **spawn_opts) -> Agent`, a FRESH
      #   agent per call; this arm passes `journal:` and the lease's `worker_env:`
      # @param grader [#grade] `grade(timeline) -> Grader::Grade`
      # @param isolation [#acquire] the injected backend (Null by default)
      # @return [Run]
      def run(task, spawn_seam:, grader:, isolation: NoIsolation)
        leased(isolation:) do |lease|
          journal = Channel.new
          # The lease's environment is CARRIED, not just acquired. An arm that
          # takes a checkout and then spawns into the process cwd makes
          # `--isolation` bill for a worktree it never writes in -- and the
          # bench's own refusal names that flag as what contains a writing
          # toolset. Unisolated, NoIsolation::Lease#worker_env is nil and the
          # seam coalesces it, so nothing about an unleased run changes.
          agent = spawn_seam.call(journal:, worker_env: lease.worker_env)
          # The ask's own value is dropped: the settled Timeline is read off the
          # agent, which is also where a multi-turn run would leave it.
          elapsed, = @instrument.timed { agent.ask(task) }
          # PRICE BEFORE GRADING, as its own statement. `Instrument#price` DRAINS
          # the journal, so this ordering is what keeps a journaling grader's own
          # spend out of the arm's cost -- and inside `Run.new`'s argument list
          # left-to-right evaluation would silently reverse it.
          ledger = @instrument.price(journal)
          Run.new(arm: name, timeline: agent.timeline, grade: grader.grade(agent.timeline), elapsed:, ledger:)
        end
      end
    end
  end
end
