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
      # @param instrument [Instrument] times the ask and prices the journal --
      #   the same measuring collaborator every arm is injected with
      # @param handoff [#reclaim] the worker-completion point, threaded to the
      #   base's own lease bracket
      def initialize(name: "single-thread", instrument: Instrument.new,
                     handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @instrument = instrument
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
      # The lease lifecycle is the base's {Arm#leased} bracket. This arm has no
      # per-worker result to fold a handoff {Isolation::WorkerHandoff::Report}
      # into, so the Handback journal is what records what the completion did.
      #
      # @param task [String] the instruction to ask
      # @param spawn_seam [#call] `call(journal:, **spawn_opts) -> Agent`, a FRESH
      #   agent per call; this arm passes only `journal:`
      # @param grader [#grade] `grade(timeline) -> Grader::Grade`
      # @param isolation [#acquire] the injected backend (Null by default)
      # @return [Run]
      def run(task, spawn_seam:, grader:, isolation: NoIsolation)
        leased(isolation:) do
          journal = Channel.new
          agent = spawn_seam.call(journal:)
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
