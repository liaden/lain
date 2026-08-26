# frozen_string_literal: true

module Lain
  class Arm
    # An adaptive-router topology. One agent, like {SingleThread}, but WHICH
    # model (and shared sibling template) it runs under is chosen by an
    # {Oracle::Router} from the task's own text, BEFORE the child exists. The
    # router is asked exactly ONCE per {#run}, and its answer becomes
    # `model:`/`template:` spawn_opts on the {Arm}'s `spawn_seam` duck.
    #
    # STRUCTURALLY, re-routing mid-session is impossible rather than merely
    # discouraged: `@router`/`@definition` are read ONLY inside {#route}, which
    # runs strictly BEFORE `spawn_seam.call`, so the running child is
    # constructed with no reference to either and the {Run} carries neither.
    # There is no second call site to gate, guard or forget -- the birth
    # boundary is the shape of the code, not a rule about it.
    #
    # COST VISIBILITY: routing children to different models puts each in a
    # different prompt-cache namespace. That trade IS the arm's whole point, but
    # it must be visible, and it is visible on two independent paths: the
    # routing decision journals as a {Telemetry::OracleAnswer} naming the chosen
    # `model`/`template`, and each child's own {Telemetry::TurnUsage} records
    # the model IT ran under, so {Ledger} and {Compare} price every run through
    # the real per-model rate rather than one blended number.
    class AdaptiveRouter < Arm
      # @param name [String] the arm's label
      # @param router [#ask, #model, #usage] the live tier answering
      #   `definition`'s question -- {Oracle::Router.heuristic} or a model tier
      # @param definition [Oracle::Definition] the SAME definition `router` was
      #   built over (its schema/template/tier) -- the journaled
      #   `oracle_digest` names the oracle that actually answered only if this
      #   matches, the same pairing {Oracle::Recorded::Journaling} already
      #   requires of ITS caller. Defaults to the heuristic-tier definition,
      #   matching {Oracle::Router.heuristic}'s own default tier.
      # @param instrument [Instrument] times the ask and prices the journal
      # @param handoff [#reclaim, #surrender] forwarded to {Arm}'s lease bracket
      def initialize(router:, name: "adaptive-router", definition: Oracle::Router.definition,
                     instrument: Instrument.new, handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @router = router
        @definition = definition
        @instrument = instrument
      end

      # Route, THEN spawn, THEN run -- in that order, and only that order.
      # `elapsed` times ONLY {Agent#ask}, matching {SingleThread}'s own
      # accounting split (the routing round trip and the grading/pricing pass
      # both run outside the clock).
      #
      # @param task [String] the instruction to ask; also the router's own
      #   question input
      # @param spawn_seam [#call] `call(journal:, **spawn_opts) -> Agent`; this
      #   arm passes `journal:`, `model:`, and `template:`
      # @param grader [#grade] `grade(timeline) -> Grader::Grade`
      # @param isolation [#acquire] the injected backend (Null by default)
      # @return [Run]
      def run(task, spawn_seam:, grader:, isolation: NoIsolation)
        leased(isolation:) do
          journal = Channel.new
          # Route, THEN run, as two statements: the ordering IS this arm's claim,
          # so it is not left to argument-evaluation order to imply.
          routed = route(task, journal:)
          graded_run(task, spawn_seam:, grader:, journal:, routed:)
        end
      end

      private

      # The ONE call site that reaches `@router`, which is the structural claim
      # above made mechanical: `model`/`template` cross into {#run} as plain
      # Strings, never as a reference back to the oracle.
      def route(task, journal:)
        Oracle::Recorded::Journaling.new(inner: @router, definition: @definition, journal:)
                                    .ask(task:).await
      end

      # Split from {#run} so neither method carries both routing and executing
      # the routed run.
      def graded_run(task, spawn_seam:, grader:, journal:, routed:)
        agent = spawn_seam.call(journal:, model: routed.model, template: routed.template)
        elapsed, = @instrument.timed { agent.ask(task) }
        # Price BEFORE grading -- see {SingleThread#run}: `#price` drains, and
        # inside an argument list evaluation order would reverse the two.
        ledger = @instrument.price(journal)
        Run.new(arm: name, timeline: agent.timeline, grade: grader.grade(agent.timeline), elapsed:, ledger:)
      end
    end
  end
end
