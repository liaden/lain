# frozen_string_literal: true

module Lain
  class Arm
    # The bottom rung of the decomposition ladder: one agent, handed the whole
    # task at once, in the checkout its lease cut. No plan is written first and
    # no gate stands in front of it -- it enters at `implementation`, below every
    # stage an epic would gate, so there is no rung at which one could.
    #
    # It is the altitude bench's FLOOR. Whatever a richer topology buys in score,
    # it buys against this arm's cost and wall-time, so the comparison is only
    # honest while this stays the cheapest thing that could possibly work.
    #
    # It differs from {SingleThread}, the control it otherwise resembles, in the
    # two things the altitude question turns on: it works inside the lease's
    # {WorkerEnv} rather than the shared process environment, and it is graded by
    # a judge built FROM that lease -- see {#initialize}'s `grading:`.
    class OneShot < Arm
      # Where it joins {Ladder}. Below `issue_plan`, which is what "no gates"
      # means structurally rather than by assertion.
      ENTRY = "implementation"

      # Grade with exactly what the caller threaded in. The default, so an arm
      # in an ordinary {Driver} comparison behaves as every other arm does; the
      # altitude bench passes a seam that builds a {Grader::LeaseHarness} over
      # the lease instead.
      PASS_THROUGH = ->(grader:, **) { grader }

      # @param name [String] the arm's label, in reports and Compare::Run names
      # @param instrument [Instrument] times the ask and prices the journal
      # @param grading [#call] `call(lease:, grader:) -> #grade`, the judge for
      #   THIS run. It is a seam rather than a plain grader because the subject's
      #   own suite can only be run while the lease still holds the checkout, and
      #   nothing outside this object ever holds that lease.
      # @param journal_factory [#call] builds the per-run journal {Instrument}
      #   drains to price the run; inject a tee to observe what went past
      # @param handoff [#reclaim, #surrender] the worker-completion point,
      #   threaded to the base's own lease bracket
      def initialize(name: "one-shot", instrument: Instrument.new, grading: PASS_THROUGH,
                     journal_factory: -> { Channel.new }, handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @instrument = instrument
        @grading = grading
        @journal_factory = journal_factory
      end

      # @return [Array<String>] the rungs this arm walks: implementation, land
      def rungs = Ladder.from(ENTRY)

      # Spawn one agent into the leased checkout, ask it the whole task, and hand
      # back the graded, priced, timed {Run}.
      #
      # `elapsed` times ONLY the ask, {SingleThread}'s discipline: grading runs a
      # whole test suite, and charging that to the arm would report a slow
      # grader as a slow topology.
      #
      # @param task [String] the instruction to ask
      # @param spawn_seam [#call] `call(journal:, **spawn_opts) -> Agent`, a
      #   FRESH agent per call; this arm passes `journal:` and `worker_env:`
      # @param grader [#grade] the Driver's own grader, used unless the grading
      #   seam says otherwise
      # @param isolation [#acquire] the injected backend
      # @param grading [#call, nil] this run's own judge seam, overriding the
      #   constructed one; a bench varies it per task
      # @return [Run]
      def run(task, spawn_seam:, grader:, isolation: NoIsolation, grading: nil)
        leased(isolation:) do |lease|
          journal = @journal_factory.call
          agent = spawn_seam.call(journal:, worker_env: lease.worker_env)
          elapsed, = @instrument.timed { agent.ask(task) }
          # Priced BEFORE grading and as its own statement: `#price` DRAINS the
          # journal, so a judge that journals anything of its own would otherwise
          # land in this arm's cost.
          ledger = @instrument.price(journal)
          Run.new(arm: name, timeline: agent.timeline, elapsed:, ledger:,
                  grade: judge(lease, grader, grading).grade(agent.timeline))
        end
      end

      private

      # A run-level seam WINS over the constructed one: a bench varies the judge
      # per task (each task's own subject project and level root), while the arm
      # is built once.
      def judge(lease, grader, grading) = (grading || @grading).call(lease:, grader:)
    end
  end
end
