# frozen_string_literal: true

module Lain
  class Arm
    # Magentic-One's dual-loop, mapped onto Lain. An outer orchestration loop
    # carries a structured {LedgerState} (facts+plan / progress+next-subtask)
    # sent-not-stored in the {Workspace}, drives the task step by step, and when
    # progress stalls for K steps fires a REPLAN -- a real transition on the same
    # {Agent::LoopMachine} the inner loop runs, journaled through its
    # `before_transition` hook so the bench can report replans as a distribution.
    #
    # The outer loop is settled by the LEDGER and bounded by `max_steps`; the
    # grader is asked exactly once, at the end. It used to settle on a grader
    # PASS, which handed this arm an oracle its controls do not get: a score
    # comparison then measured protocol rather than strategy, and an ungradeable
    # task spent the whole ceiling in model calls. NUMBERS RECORDED UNDER THE
    # OLD PROTOCOL ARE NOT COMPARABLE TO NUMBERS RECORDED UNDER THIS ONE.
    #
    # HOW a run ended is journaled rather than inferred: `:stalled` for a ledger
    # that terminally dried up, `:done` for everything else -- which means "the
    # CEILING bound it before that happened", NOT "it finished healthy". A run
    # that stalled on its last step and bought a rewrite it never got to try
    # also ends `:done`, so counting `:done` as healthy over-counts. Reading
    # either means TEE-ing the journal (see `journal_factory:` on {#run});
    # {Bench::ArmSweep} tees already but counts only `replan`, so the report it
    # prints does not yet carry the terminal state.
    #
    # The ledger rides the Workspace, NOT the Timeline: it reflects CURRENT
    # truth every step and must not accrete a stale copy per turn. One linear
    # Timeline is threaded across the steps' agents, each spawned over the
    # previous head's Store, so the returned head reaches every paid turn and
    # the {Arm::Run} reachability contract holds trivially.
    class DualLedger < Arm
      # K: consecutive no-progress steps before the outer loop replans.
      DEFAULT_STALL_LIMIT = 3
      # The outer loop's ceiling. Nothing here can judge a task COMPLETE, only
      # whether it moved, so a run whose ledger keeps advancing has no settling
      # condition of its own and the loop MUST be bounded or it never returns.
      DEFAULT_MAX_STEPS = 6
      # Steps a run needs BEYOND K to settle: one that records the first note,
      # and one after the rewrite that proves it did not take. So a config
      # settles only when `max_steps >= stall_limit + SETTLING_MARGIN`, and both
      # bounds are swept parameters -- below the relation the loop cannot reach
      # its settling step at all and silently burns the ceiling instead.
      SETTLING_MARGIN = 2

      # @param name [String] this arm's label, in reports and Compare::Run names
      # @param stall_limit [Integer] K -- no-progress steps that trigger a replan
      # @param max_steps [Integer] the outer loop's hard ceiling
      # @param progress [#call] `call(ledger:, response:, timeline:) -> LedgerState`,
      #   the step's progress reading; defaults to {DEFAULT_PROGRESS}
      # @param replanner [#call] `call(ledger:, task:) -> LedgerState`, how a
      #   stall rewrites the plan; defaults to {DEFAULT_REPLANNER}
      # @param instrument [Instrument] times the whole drive and prices the run's
      #   journal
      # @param journal_factory [#call] builds the per-run journal
      #   `Instrument#price` will drain; inject one that tees pushes into a
      #   caller-held sink to observe `ledger_transition` records first
      # @param handoff [#reclaim, #surrender] forwarded to {Arm}'s lease bracket
      # @raise [ArgumentError] when the two bounds describe a run that cannot
      #   settle -- see {SETTLING_MARGIN}
      def initialize(name: "dual-ledger", stall_limit: DEFAULT_STALL_LIMIT, max_steps: DEFAULT_MAX_STEPS,
                     progress: DEFAULT_PROGRESS, replanner: DEFAULT_REPLANNER, instrument: Instrument.new,
                     journal_factory: -> { Channel.new }, handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @stall_limit = Integer(stall_limit)
        @max_steps = Integer(max_steps)
        bound_settling!
        @progress = progress
        @replanner = replanner
        @instrument = instrument
        @journal_factory = journal_factory
      end

      # Drive the dual-loop and hand back the graded, priced, timed {Run}.
      #
      # `spawn_seam` here is the widened duck the {Arm} base documents:
      # `call(journal:, workspace:, timeline:) -> Agent`. This arm parametrizes
      # the child Workspace (the ledger) per step and threads the Timeline so the
      # conversation stays one linear, fully-reachable head.
      #
      # `Instrument#price` DRAINS the journal, which discards this arm's
      # `ledger_transition` records from the Run's own view. To count
      # replans/stalls per run, inject a `journal_factory:` that TEES pushes
      # into a caller-held sink so the transitions are observed before that
      # drain empties the channel.
      def run(task, spawn_seam:, grader:, isolation: NoIsolation)
        leased(isolation:) do |lease|
          journal = @journal_factory.call
          # The planner build sits INSIDE the span, where it has always been.
          # `elapsed` is a recorded bench number, so dropping a phase out of it
          # would make past dual-ledger runs incomparable to future ones.
          # Narrowing the span is a methodology change, never a refactor's
          # side effect.
          elapsed, state = @instrument.timed do
            drive(task, spawn_seam:, journal:, planner: build_planner(journal), lease:)
          end
          # Price BEFORE grading -- see {SingleThread#run}.
          ledger = @instrument.price(journal)
          Run.new(arm: name, timeline: state.timeline, grade: grader.grade(state.timeline), elapsed:, ledger:)
        end
      end

      private

      # A sweep sets both bounds and neither degenerate case announces itself at
      # runtime: K below 1 rewrites the plan before any step has failed to
      # progress, and a ceiling below `K + SETTLING_MARGIN` cuts the run off
      # before its settling step, which reads as "the arm always spends its
      # budget" rather than as a misconfiguration.
      def bound_settling!
        raise ArgumentError, stall_limit_refusal if @stall_limit < 1
        raise ArgumentError, max_steps_refusal if @max_steps < settling_floor
      end

      def settling_floor = @stall_limit + SETTLING_MARGIN

      def stall_limit_refusal
        "stall_limit must be at least 1 (got #{@stall_limit}) -- K counts the consecutive no-progress " \
          "steps that buy a replan, and anything lower rewrites the plan before a step has failed at all"
      end

      def max_steps_refusal
        "max_steps must be at least stall_limit + #{SETTLING_MARGIN} (#{settling_floor}) for the loop to " \
          "reach its settling step; got max_steps #{@max_steps} with stall_limit #{@stall_limit}"
      end

      def build_planner(journal)
        Planner.new(transition_listener: Journaling.new(journal))
      end

      # The outer loop, as a {Loop} folded step by step until the LEDGER settles
      # or the ceiling binds.
      #
      # The grader is deliberately NOT reachable from here: reading the scoring
      # function as a control signal is an oracle the control arms are not
      # given, so a cross-arm score comparison would measure protocol rather
      # than strategy.
      #
      # Both ways out are JOURNALED, because "why did this run stop?" is a bench
      # reading and an inference from the replan count is not one: a terminally
      # dried-up ledger leaves the machine `:stalled`, and every other exit is
      # closed here with `end_turn!` to `:done`.
      def drive(task, spawn_seam:, planner:, journal:, lease:)
        control = Loop.new(ledger: LedgerState.initial(task:), stall_limit: @stall_limit)
        until planner.terminal? || control.steps >= @max_steps
          control = step(control, task, spawn_seam:, planner:, journal:, lease:)
        end
        planner.end_turn! unless planner.terminal?
        control
      end

      # One outer step: spawn a fresh agent over the current ledger and threaded
      # Timeline, ask, read progress, and -- when the stall counter tops K --
      # announce the stall on the shared machine.
      # EVERY step carries the lease, not just the first: this arm spawns a fresh
      # agent per step, and one of them landing outside the checkout is the same
      # defect as all of them doing so. See {SingleThread#run} for the reason.
      def step(control, task, spawn_seam:, planner:, journal:, lease:)
        planner.dispatch!
        agent = spawn_seam.call(journal:, workspace: workspace_for(control.ledger), timeline: control.timeline,
                                worker_env: lease.worker_env)
        response = agent.ask(task)
        advanced = control.advance(
          timeline: agent.timeline,
          ledger: @progress.call(ledger: control.ledger, response:, timeline: agent.timeline)
        )
        advanced.stalled? ? stall(advanced, task, planner:) : advanced
      end

      # The FIRST stall buys a rewrite; a later one finds the rewrite spent and
      # leaves the machine in `:stalled`, which is what ends the drive -- so the
      # terminal stall is a record in the journal rather than a state only this
      # object knew.
      def stall(control, task, planner:)
        planner.stall!
        control.replannable? ? replan(control, task, planner:) : control
      end

      # The rewrite: back to `:awaiting_model` on the machine, a fresh plan in
      # the ledger, and one step to prove the rewrite moved anything.
      def replan(control, task, planner:)
        planner.replan!
        control.replanned(@replanner.call(ledger: control.ledger, task:))
      end

      def workspace_for(ledger)
        Workspace.empty.with(ledger.to_reminder)
      end
    end

    class DualLedger
      # The outer loop's run state, folded step by step. A RESULT CARRIER and
      # not a value object -- it holds a live Timeline, so it is deliberately
      # not `Ractor.shareable?`, {Arm::Run}'s posture.
      #
      # It carries COUNTS and the ledger, never loop STATE: what state the run
      # is in is the {Planner}'s to say, and a second copy here would be a state
      # machine nobody could see.
      #
      # `stalls` counts CONSECUTIVE no-progress steps and is deliberately not
      # reset by a replan, which is what makes the rewrite's window exactly one
      # step: `stalls == stall_limit` is the moment the plan is rewritten, and
      # any further no-progress step pushes the counter PAST K, where
      # {#replannable?} is false and the stall is terminal. A step that
      # genuinely advances resets it to zero, so a rewrite that worked earns the
      # full K steps -- and a fresh rewrite -- next time the ledger dries up.
      Loop = Data.define(:ledger, :timeline, :steps, :stalls, :stall_limit) do
        def initialize(ledger:, stall_limit:, timeline: nil, steps: 0, stalls: 0)
          super
        end

        # One step's outcome folded in: progress is "the ledger signature moved",
        # so a step that recorded nothing new increments the stall counter.
        def advance(timeline:, ledger:)
          progressed = ledger.signature != self.ledger.signature
          with(timeline:, ledger:, steps: steps + 1, stalls: progressed ? 0 : stalls + 1)
        end

        # A replan reinstalls the plan; the counter stands, so the rewritten
        # plan has one step to move the ledger.
        def replanned(ledger) = with(ledger:)

        def stalled? = stalls >= stall_limit
        def replannable? = stalls == stall_limit
      end

      # The arm's outer orchestration FSM: the SAME {Agent::LoopMachine} the
      # inner loop runs, so a stall becomes a first-class journaled
      # `stall! -> replan!` transition pair rather than an untracked `if`. The
      # inherited `before_transition` hook announces every move to the injected
      # listener; nothing here overrides the machine.
      class Planner
        include Agent::LoopMachine

        def initialize(transition_listener:)
          super() # state_machines seeds :awaiting_user through the super chain.
          @transition_listener = transition_listener
        end

        # Asking the machine is what keeps "what state is this run in" in ONE
        # place; the drive holds counters, not a second answer.
        def terminal? = stalled? || done?
      end

      # The {Agent::TransitionListener} the {Planner} announces to. The machine's
      # hook is the only path to this journal.
      class Journaling
        def initialize(journal)
          @journal = journal
        end

        def on_transition(from:, to:, event:)
          @journal << LedgerTransition.new(from:, to:, event:)
          self
        end
      end

      # A journaled orchestration transition, so {Compare} can report replans and
      # stalls as a distribution alongside tokens and wall-time. Its own journal
      # type, so {Ledger}'s `turn_usage`-only fold ignores it and pricing is
      # unaffected.
      LedgerTransition = Data.define(:from, :to, :event) do
        include Telemetry::Journalable

        def initialize(from:, to:, event:)
          super(from: from.to_sym, to: to.to_sym, event: event.to_sym)
        end
      end

      # The default progress heuristic, `call(ledger:, response:, timeline:)`.
      # With no model in the loop to JUDGE progress, "the ledger moved" is
      # approximated structurally: a step advanced only if it said something
      # NON-EMPTY that DIFFERS from the last thing recorded. A model looping on
      # identical output -- the canonical Magentic-One stall -- repeats its last
      # note, so the signature does not move and the stall counter climbs.
      #
      # Deliberately crude: it cannot tell real work from a reworded non-answer,
      # and exists so the stall path is REACHABLE without wiring anything. It is
      # also what SETTLES the outer loop, so a detector swapped in here decides
      # both when the arm replans and when it stops.
      DEFAULT_PROGRESS = lambda do |ledger:, response:, **|
        note = response.text.to_s.strip
        moved = !note.empty? && note != ledger.progress.last
        moved ? ledger.advanced(note:, next_subtask: ledger.next_subtask) : ledger
      end

      # The default replan: keep the facts and work done, install a retry plan
      # and a fresh subtask. The changed subtask is what moves the signature so
      # the stall counter's reset means something. `call(ledger:, task:)`.
      DEFAULT_REPLANNER = lambda do |ledger:, task:|
        ledger.replanned(plan: ledger.plan + ["replan attempt for: #{task}"], next_subtask: "retry: #{task}")
      end
    end
  end
end
