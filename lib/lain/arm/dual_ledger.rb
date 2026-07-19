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
    # The ledger rides the Workspace (`#with`), NOT the Timeline: it reflects
    # CURRENT truth every step and must not accrete a stale copy per turn (the
    # whole point of sent-not-stored). One linear Timeline is threaded across the
    # steps' agents (each spawned over the previous head's Store), so the
    # returned head reaches every paid turn -- the {Arm::Run} reachability
    # contract holds trivially here, exactly as it does for {SingleThread}.
    class DualLedger < Arm
      # K: consecutive no-progress steps before the outer loop replans.
      DEFAULT_STALL_LIMIT = 3
      # The outer loop's ceiling. A mock repeats its last response forever and a
      # stalled run makes no progress by definition, so the loop MUST be bounded
      # or it never returns; this is that bound.
      DEFAULT_MAX_STEPS = 6

      # @param stall_limit [Integer] K -- no-progress steps that trigger a replan
      # @param max_steps [Integer] the outer loop's hard ceiling
      # @param progress [#call] `call(ledger:, response:, timeline:) -> LedgerState`,
      #   the step's progress reading; defaults to {DEFAULT_PROGRESS}
      # @param replanner [#call] `call(ledger:, task:) -> LedgerState`, how a
      #   stall rewrites the plan; defaults to {DEFAULT_REPLANNER}
      def initialize(name: "dual-ledger", stall_limit: DEFAULT_STALL_LIMIT, max_steps: DEFAULT_MAX_STEPS,
                     progress: DEFAULT_PROGRESS, replanner: DEFAULT_REPLANNER,
                     clock: SingleThread::DEFAULT_CLOCK, price_book: PriceBook.default,
                     journal_factory: -> { Channel.new })
        super(name:)
        @stall_limit = Integer(stall_limit)
        @max_steps = Integer(max_steps)
        @progress = progress
        @replanner = replanner
        @clock = clock
        @price_book = price_book
        @journal_factory = journal_factory
      end

      # Drive the dual-loop and hand back the graded, priced, timed {Run}.
      #
      # `spawn_seam` here is the widened duck the {Arm} base documents:
      # `call(journal:, workspace:, timeline:) -> Agent`. This arm parametrizes
      # the child Workspace (the ledger) per step and threads the Timeline so the
      # conversation stays one linear, fully-reachable head.
      def run(task, spawn_seam:, grader:, isolation: NoIsolation)
        lease = isolation.acquire(name)
        journal = @journal_factory.call
        state = nil
        elapsed = timed { state = drive(task, spawn_seam:, grader:, journal:, planner: build_planner(journal)) }
        graded_run(state, grader:, elapsed:, ledger: price(journal))
      ensure
        lease&.release
      end

      private

      def build_planner(journal)
        Planner.new(transition_listener: Journaling.new(journal))
      end

      # Fold the run's journal into a priced {Ledger} -- turn_usage records only;
      # the ledger_transition records ride along and are ignored here.
      #
      # NOTE for B12: this DRAINS the journal, which discards the transition
      # records from the Run's own view -- the returned {Run} carries a priced
      # Ledger, not the raw transition stream. To count replans/stalls per run,
      # inject a `journal_factory:` that TEES pushes into a caller-held sink
      # (see the arm spec's `recording_journal`) so the transitions are observed
      # before this drain empties the channel.
      def price(journal)
        Ledger.from_journal(journal.drain.map(&:to_journal), price_book: @price_book)
      end

      def graded_run(state, grader:, elapsed:, ledger:)
        Run.new(arm: name, timeline: state.timeline, grade: grader.grade(state.timeline), elapsed:, ledger:)
      end

      # The outer loop, as a small mutable {Loop} folded step by step until it
      # settles (grader pass) or hits the ceiling. Extracted from #run so the
      # bridge (timing/pricing) and the iteration read as separate concerns, the
      # way {Agent#run}/{Agent#run_loop} split.
      def drive(task, spawn_seam:, grader:, planner:, journal:)
        control = Loop.new(ledger: LedgerState.initial(task:), stall_limit: @stall_limit)
        until control.settled? || control.steps >= @max_steps
          control = step(control, task, spawn_seam:, grader:, planner:, journal:)
        end
        control
      end

      # One outer step: spawn a fresh agent over the current ledger and threaded
      # Timeline, ask, read progress, and -- when the stall counter tops K --
      # fire a journaled replan and reinstall a fresh plan.
      def step(control, task, spawn_seam:, grader:, planner:, journal:)
        planner.dispatch!
        agent = spawn_seam.call(journal:, workspace: workspace_for(control.ledger), timeline: control.timeline)
        response = agent.ask(task)
        advanced = control.advance(
          timeline: agent.timeline,
          ledger: @progress.call(ledger: control.ledger, response:, timeline: agent.timeline),
          settled: grader.grade(agent.timeline).pass?
        )
        advanced.stalled? ? replan(advanced, task, planner:) : advanced
      end

      # React to a stall: the journaled `stall! -> replan!` pair on the shared
      # LoopMachine (announced through `before_transition`), then a fresh plan
      # and a reset counter so the loop can make progress again.
      def replan(control, task, planner:)
        planner.stall!
        planner.replan!
        control.replanned(@replanner.call(ledger: control.ledger, task:))
      end

      def workspace_for(ledger)
        Workspace.empty.with(ledger.to_reminder)
      end

      def timed
        started = @clock.call
        yield
        @clock.call - started
      end
    end

    # The outer loop's run state, folded step by step. A RESULT CARRIER, not a
    # value object (it holds a live Timeline, so it is deliberately not
    # `Ractor.shareable?` -- the same posture {Arm::Run} takes): each transition
    # returns a fresh Loop so {DualLedger#drive}'s `until` can reassign its
    # handle without mutating shared state.
    #
    # `stalls` counts CONSECUTIVE no-progress steps; a step whose ledger
    # signature advanced resets it to zero, and it tops out at `stall_limit`,
    # which is when {#stalled?} flips and the arm replans.
    class DualLedger
      Loop = Data.define(:ledger, :timeline, :steps, :stalls, :stall_limit, :settled) do
        def initialize(ledger:, stall_limit:, timeline: nil, steps: 0, stalls: 0, settled: false)
          super
        end

        # One step's outcome folded in: progress is "the ledger signature moved",
        # so a step that recorded nothing new increments the stall counter.
        def advance(timeline:, ledger:, settled:)
          progressed = ledger.signature != self.ledger.signature
          with(timeline:, ledger:, settled:, steps: steps + 1, stalls: progressed ? 0 : stalls + 1)
        end

        # A replan reinstalls the plan and resets the stall counter -- the loop
        # is unstuck and gets another K steps before it would replan again.
        def replanned(ledger) = with(ledger:, stalls: 0)

        def stalled? = stalls >= stall_limit
        def settled? = settled
      end

      # The arm's outer orchestration FSM: the SAME {Agent::LoopMachine} the
      # inner loop runs, instantiated fresh per run and driven by the arm's
      # control so a stall becomes a first-class, journaled `stall! -> replan!`
      # transition pair rather than an untracked `if`. Its `before_transition`
      # hook (inherited from the mixin) announces every move to the injected
      # listener; nothing here overrides the machine.
      class Planner
        include Agent::LoopMachine

        def initialize(transition_listener:)
          super() # state_machines seeds :awaiting_user through the super chain.
          @transition_listener = transition_listener
        end
      end

      # The transition listener the {Planner} announces to: it turns each move
      # into a {LedgerTransition} on the run's Journal, which is precisely what
      # "journaled via before_transition" means -- the only path to this journal
      # is the machine's hook. Satisfies the {Agent::TransitionListener} duck.
      class Journaling
        def initialize(journal)
          @journal = journal
        end

        def on_transition(from:, to:, event:)
          @journal << LedgerTransition.new(from:, to:, event:)
          self
        end
      end

      # A journaled orchestration transition -- so {Compare} can report replans
      # and stalls as a distribution alongside tokens and wall-time. Its own
      # journal type (`ledger_transition`), so {Ledger}'s `turn_usage`-only fold
      # ignores it and pricing is unaffected. Deeply frozen (Symbols only), so it
      # is `Ractor.shareable?` like every other {Telemetry} event.
      LedgerTransition = Data.define(:from, :to, :event) do
        include Telemetry::Journalable

        def initialize(from:, to:, event:)
          super(from: from.to_sym, to: to.to_sym, event: event.to_sym)
        end
      end

      # The default progress heuristic. With no model in the loop to JUDGE
      # progress, "the ledger moved" is approximated structurally: a step
      # advanced only if it said something NON-EMPTY that DIFFERS from the last
      # thing recorded. A model looping on identical output -- the canonical
      # Magentic-One stall -- repeats its last note, so the ledger (and thus its
      # `signature`) does not move and the stall counter climbs until it replans.
      # This is deliberately crude (it cannot tell real work from a reworded
      # non-answer); it exists so the stall path is REACHABLE without wiring
      # anything, and the `progress:` seam is where a smarter detector goes.
      # `call(ledger:, response:, timeline:)`.
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
