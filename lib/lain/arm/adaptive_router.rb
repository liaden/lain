# frozen_string_literal: true

module Lain
  class Arm
    # OR-5: an adaptive-router topology. One agent, like {SingleThread}, but
    # WHICH model (and shared sibling template) it runs under is chosen by an
    # oracle from the task's own text, BEFORE the child exists --
    # {Oracle::Router}. The router is asked exactly ONCE per `#run`, and its
    # answer becomes `model:`/`template:` spawn_opts on the {Arm}'s own
    # `spawn_seam` duck (`call(journal:, **spawn_opts) -> Agent`) -- exactly
    # the widening `arm_spec`'s toy routing arm pins, made real with an
    # oracle-backed decision instead of a hardcoded model.
    #
    # STRUCTURALLY, re-routing mid-session is impossible, not merely
    # discouraged (AC2): `@router`/`@definition` are read ONLY inside
    # `#route`, which runs strictly BEFORE `spawn_seam.call` -- so the running
    # child (the `Agent` `spawn_seam` hands back) is constructed with no
    # reference to either, no method on `Agent` reaches them, and `Run` (the
    # only object `#run` hands back) carries neither. `#route` is the ONE call
    # site that ever asks the router; there is no second one to gate, guard,
    # or forget, because a running child never receives the router to call it
    # again -- the birth boundary is the shape of the code, not a rule about it.
    #
    # COST VISIBILITY: routing children to different models puts each in a
    # different prompt-cache namespace -- that trade IS the arm's whole point
    # (a cheap model for an easy task, a strong one for a hard task), but it
    # must be visible, never hidden. It is visible on two independent paths: 1)
    # the routing decision itself journals as a {Telemetry::OracleAnswer}
    # naming the chosen `model`/`template` (AC1), and 2) each child's own
    # {Telemetry::TurnUsage} records the model IT actually ran under, so
    # {Ledger}/{Compare} price every run through the real per-model rate --
    # nothing here averages or masks a cross-model run into one blended number.
    class AdaptiveRouter < Arm
      # Monotonic wall-clock, the same choice and rationale as
      # {SingleThread::DEFAULT_CLOCK}.
      DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # @param name [String] the arm's label
      # @param router [#ask, #model, #usage] the live tier answering
      #   `definition`'s question -- {Oracle::Router.heuristic} or a model tier
      # @param definition [Oracle::Definition] the SAME definition `router` was
      #   built over (its schema/template/tier) -- the journaled
      #   `oracle_digest` names the oracle that actually answered only if this
      #   matches, the same pairing {Oracle::Recorded::Journaling} already
      #   requires of ITS caller. Defaults to the heuristic-tier definition,
      #   matching {Oracle::Router.heuristic}'s own default tier.
      # @param clock [#call] returns a monotonic seconds Float; injectable
      # @param price_book [PriceBook] prices the run's journal into dollars
      def initialize(router:, name: "adaptive-router", definition: Oracle::Router.definition,
                     clock: DEFAULT_CLOCK, price_book: PriceBook.default)
        super(name:)
        @router = router
        @definition = definition
        @clock = clock
        @price_book = price_book
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
        lease = isolation.acquire(name)
        journal = Channel.new
        routed = route(task, journal:)
        graded_run(task, spawn_seam:, grader:, journal:, routed:)
      ensure
        lease&.release
      end

      private

      # The ONE call site that reaches `@router` (AC2's structural claim, made
      # mechanical): ask it, journal the answer via the same
      # {Oracle::Recorded::Journaling} decorator {Oracle::Recorded} itself
      # documents, and return the typed answer -- `model`/`template` cross
      # into `#run` as plain Strings, never as a reference back to the oracle
      # or this method.
      def route(task, journal:)
        Oracle::Recorded::Journaling.new(inner: @router, definition: @definition, journal:)
                                    .ask(task:).await
      end

      # Spawn under the already-routed `model:`/`template:`, run, grade, and
      # price -- split from {#run} as its own responsibility (routing vs.
      # executing the routed run) so neither method carries both.
      def graded_run(task, spawn_seam:, grader:, journal:, routed:)
        agent = spawn_seam.call(journal:, model: routed.model, template: routed.template)
        elapsed = timed { agent.ask(task) }
        ledger = Ledger.from_journal(journal.drain.map(&:to_journal), price_book: @price_book)
        Run.new(arm: name, timeline: agent.timeline, grade: grader.grade(agent.timeline), elapsed:, ledger:)
      end

      # Run the block, returning the monotonic seconds it took -- see
      # {SingleThread#timed} for the same shape and rationale.
      def timed
        started = @clock.call
        yield
        @clock.call - started
      end
    end
  end
end
