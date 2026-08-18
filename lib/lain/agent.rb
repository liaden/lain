# frozen_string_literal: true

require "async"
require "monitor"
require "state_machines"
require "active_support/core_ext/module/delegation"

require_relative "agent/accounting"
require_relative "agent/budget"
require_relative "agent/collaborators"
require_relative "agent/instrumentation"
require_relative "agent/loop_machine"
require_relative "agent/model_caller"
require_relative "agent/pipeline_source"
require_relative "agent/request_override"
require_relative "agent/tool_runner"
require_relative "agent/transition_listener"

module Lain
  # The loop, written as an explicit state machine rather than a while-loop with
  # a stack of conditionals.
  #
  # The difference is not stylistic. Every `stop_reason` the wire can carry must
  # have somewhere to go, and a `case` with no `else` is how a new enum value --
  # or a forgotten old one like `:stop_sequence` -- becomes a turn that silently
  # does nothing. Here each reason is a named transition and {StopReason::UNKNOWN}
  # is a real destination, so an unrecognized value fails loudly instead of
  # falling through.
  #
  # The Agent owns the loop. Both SDKs offered to own it (`tool_runner`,
  # `Chat#complete`) and both were declined, because the loop is what this project
  # exists to study.
  class Agent
    # The state machine -- states, legal transitions, and the journaling seam --
    # is declared in {LoopMachine} and mixed in here. It also defines {STATES}.
    include LoopMachine

    # The settled half of {STATES}: the loop is waiting on the human, or it is
    # over. `:stalled` and `:awaiting_approval` are deliberately absent -- both
    # are mid-run PARKS that a run resumes from, not a settled loop.
    #
    # Homed here, beside the derived {STATES}, because it is loop vocabulary
    # rather than any one reader's policy: {CLI::ResendBridge} gates a resend on
    # it, and it had been defined there and in the prompt line independently,
    # byte-identical, cross-referenced from neither side. Two copies of one
    # closed set over a machine that can gain a state is a drift waiting to
    # happen; this is the single definition.
    QUIESCENT = %i[awaiting_user done failed].freeze

    # Kept for callers that rescue the harness's own halt. See Agent::Budget.
    BudgetExceeded = Budget::Exceeded

    # The diagnostic each failing stop_reason records. A lookup table, not control
    # flow: every StopReason whose event transitions to :failed has an entry.
    FAILURE_REASONS = { StopReason::MAX_TOKENS => "model hit max_tokens before finishing",
                        StopReason::REFUSAL => "model refused to continue",
                        StopReason::UNKNOWN => "unrecognized stop_reason from provider" }.freeze
    private_constant :FAILURE_REASONS

    # `request_override` is public on purpose: it is T18's access path -- the
    # ResendBridge queues an edited Request through this reader rather than
    # threading its own handle through construction.
    attr_reader :timeline, :toolset, :context, :workspace, :session,
                :iterations, :failure_reason, :budget, :request_override, :dispatch_lock

    # {Accounting} owns the run's token roll-up; the Agent just exposes it.
    delegate :usage, to: :@accounting

    # The argument list is long because the Agent is the wiring point of the whole
    # harness, and the honest split is three-way, not one big bag: values that are
    # ALREADY their own collaborators ({Budget}, {Instrumentation}); the injected
    # *collaborators* it drives (toolset, context, the
    # {ModelCaller}/{ToolRunner}/{Accounting} triple); and the mutable *run state*
    # it seeds ({#seed_run_state}). A `Wiring` value object grouping the
    # collaborators was considered and rejected: it would not remove
    # `seed_run_state` (run state is orthogonal to collaborators) and it would
    # move the public keyword surface -- which the `provider_parity` shared group
    # and the state-machine specs construct against by name -- for no reduction in
    # moving parts. So the seam stays here, named. ({Collaborators} is not that
    # object: it resolves what these keywords MEAN and moves none of them.)
    #
    # Two styles, one seam. The three objects the loop drives may be handed over
    # WHOLE -- `model_caller:`, `tool_runner:`, `accounting:` -- or as the
    # INGREDIENTS each is built from, which is what every caller did before they
    # were injectable: `provider:`/`model_middleware:`, `handler:`/`tool_middleware:`/
    # `tool_observer:`, `journal:`. Both are supported; mixing them for ONE
    # collaborator raises ({Collaborators} owns that rule).
    #
    # `instrumentation:` (T22) is the same story for the seven keywords a run
    # REPORTS through, which used to sit here as seven slots and cost this class
    # seven signature lines. They are still accepted, through `**instrumented`,
    # and {Instrumentation.resolve} builds the value from them -- so every
    # existing call site keeps its meaning and an unknown keyword is still an
    # ArgumentError, now Data's own. Saying both is refused.
    #
    # Every collaborator keyword defaults to {Collaborators::OMITTED} rather than
    # to its value, because the resolution has to tell "not written" from
    # "written" -- and it cannot default to `nil` either, since an explicit `nil`
    # is a caller mistake {Collaborators} refuses rather than reads as a default.
    # The marker never escapes this constructor, and the NAMED default it stands
    # for is resolved once, inside {Collaborators}.
    #
    # @param toolset [Lain::Toolset] the run's capability set, rendered into
    #   every Request and shared with `tool_runner:` -- {Collaborators} refuses
    #   construction if the two disagree.
    # @param context [Lain::Context] the base rendering strategy, `(Timeline,
    #   Toolset, Workspace) -> Request`. Asked for per turn through
    #   `instrumentation.pipeline_source` rather than read off this ivar
    #   directly, so a strategy that must re-decide every turn (compaction) has
    #   somewhere to stand.
    # @param instrumentation [Instrumentation] where this run's records, phases
    #   and observers go. Defaults to the all-Null value: a run that reports
    #   nowhere, which is what an Agent built with no reporting keywords always
    #   was.
    # @param model_caller [ModelCaller] the run's ModelCaller, handed over
    #   WHOLE rather than built from `provider:`/`model_middleware:`. Defaults
    #   to {Collaborators::OMITTED}; {Collaborators} resolves what an omitted
    #   value means.
    # @param provider [Provider] the raw provider a ModelCaller gets built over
    #   when `model_caller:` is not written -- the INGREDIENT half of that same
    #   collaborator, paired with `model_middleware:` on `instrumentation:`.
    #   Defaults to {Collaborators::OMITTED}.
    # @param tool_runner [ToolRunner] the run's ToolRunner, handed over WHOLE
    #   rather than built from `handler:`/`tool_middleware:`/`tool_observer:`.
    #   Defaults to {Collaborators::OMITTED}.
    # @param handler [Effect::Handler] the tool-effect interpreter a ToolRunner
    #   gets built over when `tool_runner:` is not written -- the INGREDIENT
    #   half of that same collaborator. Defaults to {Collaborators::OMITTED}.
    # @param accounting [Agent::Accounting] the run's token roll-up, handed
    #   over WHOLE rather than built from `journal:`. Defaults to
    #   {Collaborators::OMITTED}.
    # @param timeline [Timeline, nil] the run's causal history. `nil` (the
    #   default) builds an empty Timeline over a fresh {Store} -- the common
    #   case; a caller resuming a session hands one in.
    # @param workspace [Workspace] the sent-not-stored files/tools context
    #   rendered into every Request. Frozen, and never appended to the
    #   Timeline -- see the architecture note above {Workspace}'s own class.
    # @param session [Session] the run's mutable scratch state (files read,
    #   the todo list) -- deliberately off the Timeline, so forking or
    #   rewinding it can never resurrect or lose one.
    # @param mailbox [Context::Mailbox] pending actor messages folded into the
    #   rendered tail (OM-3). Defaults to the Null combinator, which folds
    #   nothing.
    # @param budget [Budget] the ceilings that bound this autonomous loop; a
    #   budget stop is the harness deciding to halt, not a model outcome.
    # @param request_override [RequestOverride] the one-shot slot a frontend
    #   resend queues an edited Request into (T18); the next dispatch sends it
    #   byte-identically and the slot empties itself.
    # @param context_window [#occupancy] the book {#occupancy} measures
    #   against. Constructor state rather than a per-call default because the
    #   one caller that renders the figure to a human --
    #   {Frontend::PromptComposer::RunState} -- calls `#occupancy` with no
    #   keyword; a per-call default left the REPL prompt dividing by
    #   {ContextWindow::CONSERVATIVE_FALLBACK} while `.lain/state.json` divided
    #   by the served window, and two surfaces disagreeing about one turn is
    #   worse than both being uniformly wrong. A wired chat is handed
    #   {CLI::Backend#context_window}; the default degrades as it always did.
    # @param snapshot_writer [Workspace::Snapshot] captures which files a
    #   turn's tools wrote, as a causal-only Store event; a read-only turn
    #   lands nothing.
    # @param instrumented [Hash{Symbol => Object}] the seven keywords a run
    #   REPORTS through (`turn_middleware:`, `transition_listener:`, etc.),
    #   accepted directly so every call site that predates `instrumentation:`
    #   (T22) keeps its meaning; {Instrumentation.resolve} builds the value
    #   from them, and writing both `instrumentation:` and one of these raises.
    def initialize(toolset:, context:, instrumentation: Collaborators::OMITTED,
                   model_caller: Collaborators::OMITTED, provider: Collaborators::OMITTED,
                   tool_runner: Collaborators::OMITTED, handler: Collaborators::OMITTED,
                   accounting: Collaborators::OMITTED, timeline: nil, workspace: Workspace.empty,
                   session: Session.new, mailbox: Context::Mailbox::Null,
                   budget: Budget.new, request_override: RequestOverride::None,
                   snapshot_writer: Workspace::Snapshot.new, context_window: ContextWindow.default,
                   **instrumented)
      super() # state_machines sets the initial state through the super chain.
      @toolset = toolset
      @context = context
      @timeline = timeline || Timeline.empty(store: Store.new)
      @workspace = workspace
      @mailbox = mailbox
      @context_window = context_window
      wire_callers(request_override:, instrumentation:, instrumented:,
                   model_caller:, tool_runner:, accounting:, provider:, handler:)
      seed_run_state(session, snapshot_writer, budget)
    end

    # Append a user turn and run until the loop settles.
    #
    # A new user turn reopens a settled loop, so asking again after `:done` (or
    # `:failed`) continues the conversation rather than raising on `dispatch!`
    # from a terminal state. The guard keeps the very first `ask` transition-free.
    #
    # `on_stream_started` is CE-5's first-token observer, forwarded verbatim to
    # {#run}: a sibling fan-out ({Tools::Subagent::Stagger}) hands each child
    # Agent one so the child's first provider round trip signals the stagger
    # gate. It defaults to nil and is INERT then -- the whole plumb down to the
    # provider is byte-identical when no observer is wired.
    #
    # @return [Lain::Response] the final assistant response
    def ask(text, on_stream_started: nil)
      @dispatch_lock.synchronize do
        reopen! unless awaiting_user?
        @timeline = @timeline.commit(role: :user, content: [{ "type" => "text", "text" => text }])
        run(on_stream_started:)
      end
    end

    # Drive the machine from its current Timeline. Separated from {#ask} so a
    # rewound or forked Timeline can be resumed without inventing a user turn.
    # The turn phase's env is deliberately minimal: `iteration` is the count of
    # turns already committed (0 for the very first), and `timeline` is the
    # Timeline as of the START of this turn -- the node a future speculative-
    # fork middleware would fork from, before this turn's own commit lands. The
    # block adds `:response`/`:settled` on the way back out, the same in/out
    # shape #call_model uses for `:request`/`:response`. This is the seam for
    # the future budget/iteration-ceiling/interrupt-hook/speculative-fork point
    # -- placing it, not building those features yet.
    #
    # The Sync bridge: the loop always executes inside a fiber reactor, so its
    # IO (the provider round trip, a `bash` shellout) yields to the scheduler
    # and a `Budget#interrupt` lands as structured cancellation at those yield
    # points. `Sync` joins the caller's reactor when there is one (so an outer
    # `Async` can stop this run) and spins one up transparently when there is
    # not -- which is why every non-reactor caller in the suite is unchanged.
    # `@dispatch_lock` makes a run EXCLUSIVE: at most one drives the loop at a
    # time. It is reentrant (a Monitor), so #ask -> #run and a bridged resend
    # that re-enters #run each hold it once. The seam exists for T18: the
    # {CLI::ResendBridge} runs on the Neovim resend-worker thread while a user
    # prompt runs #ask on the conductor's reactor, both driving THIS agent's
    # bare-ivar state -- so the bridge's quiescence gate would be a
    # check-then-act race across the two. The bridge acquires this lock
    # (`try_enter`) to make its gate check-and-act atomic; a busy agent it
    # cannot enter is a refusal, not a wedge (see the bridge).
    def run(on_stream_started: nil) = @dispatch_lock.synchronize { Sync { run_loop(on_stream_started) } }

    # Is a dispatch in flight RIGHT NOW? A different question from {#state},
    # which records what the loop was last doing, and the two disagree exactly
    # when a turn is TORN: {#reopen!} fires at the start of the next {#ask}, so
    # a run that raised out leaves the machine parked at `:awaiting_model`
    # indefinitely while nothing runs. `Monitor#synchronize` releases on the way
    # out of a raise, so the lock does not lie about that -- and being held by
    # any thread, not just this one, it answers for a bridged resend driving the
    # loop from another thread too.
    #
    # A snapshot, not a reservation: a caller that needs the answer to STAY true
    # must hold the lock itself, which is what {CLI::ResendBridge} does with
    # `try_enter`. A caller merely describing the run -- the prompt line -- wants
    # exactly this read, and wants it without acquiring anything.
    def dispatching? = @dispatch_lock.mon_locked?

    # `#done?` and `#failed?` are generated by the state machine, one predicate
    # per state, so they cannot disagree with the declared state set.

    # How full the context is right now, as a fraction of the live model's
    # window: 0.5 is half spoken for. The numerator is {Accounting}'s LAST-turn
    # input tokens, never its cumulative `#usage` -- a cumulative sum only ever
    # grows, so it would report a context that never empties even after a
    # compaction dropped the head. It is the same reading {Compaction::Need}'s
    # window signal measures, through the same book, so a status line and the
    # compaction trigger cannot tell a user two different stories.
    #
    # `context.model` is read per call rather than captured, so a mid-session
    # `/model` switch ({Context::ModelSwitch}) moves the denominator with it.
    #
    # The one story holds only while this reader and {Compaction::Source} ask
    # the SAME book. Both take one at CONSTRUCTION now, and a live chat hands
    # both the same instance ({CLI::Backend#context_window}, memoized for the
    # run), so they cannot come apart -- which they could while this defaulted
    # per call and a wiring swapped only the Source's.
    #
    # @param context_window [#occupancy] the window book, defaulting to the one
    #   this Agent was CONSTRUCTED with. Written explicitly only by a caller
    #   measuring a run against a window that is not the run's own -- a bench
    #   arm sweeping candidate windows.
    # @return [Float, nil] nil before any turn -- absence, not an empty context
    # @raise [ContextWindow::UnknownModel] if the live model slot is nil or
    #   blank (a wiring bug, and the book stays loud about one), or if the model
    #   matches nothing in a book configured with no fallback. This reader is as
    #   loud as the book it asks: a caller rendering it per prompt either
    #   guarantees a model or rescues.
    # @raise [ArgumentError] if the book answers a non-positive window, which
    #   measures as Infinity or NaN rather than as a reading. Unreachable
    #   through {ContextWindow.default}; a caller passing its own book owns it.
    def occupancy(context_window: @context_window)
      context_window.occupancy(@accounting.last_turn_usage, model: context.model).ratio
    end

    # Time travel: the loop can be resumed from any earlier turn, which is what
    # makes speculative branching possible once a grader exists.
    def rewind(count = 1)
      @timeline = @timeline.rewind(count)
      reopen!
      self
    end

    private

    # The loop itself, hosted inside the reactor {#run} establishes. Kept apart
    # from #run so the bridge (`Sync`) and the iteration (`loop`) read as the two
    # separate concerns they are.
    def run_loop(on_stream_started)
      @failure_reason = nil

      loop do
        env = @instrumentation.turn_middleware.call({ iteration: @iterations, timeline: @timeline }) do |inner|
          response = step(on_stream_started)
          inner.merge(response:, settled: transition(response) == :settled)
        end
        return env.fetch(:response) if env.fetch(:settled)
      end
    end

    # The collaborators the loop drives -- the provider round trip, tool dispatch
    # and the token ledger, the first two each behind their own
    # {Middleware::Stack} -- plus the turn stack the loop wraps every iteration
    # in and the one-shot {RequestOverride} slot #call_model consults before
    # rendering. Grouped out of #initialize so the constructor reads as the
    # wiring seam its own comment describes rather than growing a line per
    # collaborator.
    #
    # {Instrumentation} and {Collaborators} each own one half of the two-style
    # resolution -- handed over whole or built from the individual keywords, and
    # the clash rule that forbids saying both. Both resolve eagerly, so a wiring
    # mistake raises HERE and not on the first turn. `instrumented` reaches the
    # resolver too, because four of its members (`journal`, the model and tool
    # phases, the observer) are also {Collaborators} ingredients and the clash
    # table is keyed on the keywords a caller actually wrote.
    def wire_callers(request_override:, instrumentation:, instrumented:, **collaborators)
      @instrumentation = Instrumentation.resolve(instrumentation, instrumented)
      resolved = Collaborators.new(toolset: @toolset, instrumentation: @instrumentation, **collaborators,
                                   **instrumented.slice(*Collaborators::KEYWORDS))
      @request_override = request_override
      @model_caller = resolved.model_caller
      @tool_runner = resolved.tool_runner
      @accounting = resolved.accounting
    end

    # The mutable run context, kept apart from #initialize on purpose: the
    # collaborators above are the immutable wiring, and these are the state
    # a run mutates as it goes -- the observer the machine announces transitions
    # to, the run's single mutable Session (read-set + write-set + reminders,
    # which -- unlike everything the model sees -- never enters the Timeline),
    # the snapshot writer (stateful: it remembers the last files map it wrote,
    # so it is run state exactly as the Session is), the per-turn Context source
    # (stateful for the same reason -- a live {PipelineSource} accumulates
    # cache-warmth and idle readings ACROSS turns, which is why it is asked
    # rather than recomputed), and the iteration count. Naming that seam is the
    # point; the machine owns the state ITSELF (initial: :awaiting_user), so it
    # is not seeded here.
    #
    # {Accounting} is the one that moved: it is run state too (a ledger a run
    # mutates), but since T21 a caller may inject one, and resolving it beside
    # the two collaborators it is chosen with keeps that decision in one place.
    #
    # The transition listener is read off {Instrumentation} rather than taken as
    # a parameter, because that value is where "where does this run report" is
    # decided. It is the one member copied to an ivar, because {LoopMachine}
    # announces through it from a mixin; the turn stack and the per-turn Context
    # source are asked of the value at their single use sites instead.
    # The {Budget} is seeded HERE rather than beside the collaborators, with the
    # counter it bounds: `#step` reads `@budget.check_iterations!(@iterations)`
    # and increments `@iterations` on the next line, and a ceiling separated
    # from the count it governs is a pair a reader has to reassemble. The value
    # itself is immutable; what makes it belong here is that only run state
    # gives it meaning.
    def seed_run_state(session, snapshot_writer, budget)
      @transition_listener = @instrumentation.transition_listener
      @session = session
      @snapshot_writer = snapshot_writer
      @budget = budget
      @iterations = 0
      @dispatch_lock = Monitor.new
    end

    # One turn: bound, count, ask the model, account, record. Extracted from #run
    # so the loop reads as what it is -- iterate until the machine settles.
    def step(on_stream_started)
      @budget.check_iterations!(@iterations)
      @iterations += 1
      # The turn's inbox is snapshotted HERE, before the render, and that one
      # frozen Snapshot is what both sides of the turn consume: the render-side
      # Mailbox fold (the OM-6 pipeline wiring) and this turn's commit. The
      # shared log is mutable DURING the provider round trip -- an actor reply
      # can land mid-dispatch -- so neither side may read it live: a live read
      # at commit would claim that arrival as a causal parent of a turn that
      # never rendered it, marking it consumed and losing it (panel probe #2).
      # Captured per turn and consumed only by a successful commit, so a raised
      # dispatch drops the snapshot and the next turn re-captures: re-folds.
      inbox = @mailbox.capture(@timeline)
      call_model(on_stream_started).tap { |response| commit_and_account(response, inbox) }
    end

    # The commit->journal pair, shielded as ONE atom against cancellation.
    # `defer_stop` holds a Budget#interrupt off until the region exits, so a
    # stop can never land between the Timeline commit and its TurnUsage journal
    # write -- bench cost accounting reads the Journal, and a committed turn
    # whose usage record vanished with an interrupt would silently price as
    # free. A stop requested inside the region still lands, at its exit; note
    # it also preempts a raise from inside the region (a simultaneous stop and
    # token-ceiling bust settles as the stop -- both are harness halts).
    def commit_and_account(response, inbox)
      Async::Task.current.defer_stop do
        # Correctness gate 1: commit the FULL content -- text, thinking, AND
        # tool_use blocks. Extracting only the text corrupts the very next turn.
        # `inbox` is the frozen Snapshot #step captured at turn start -- the
        # same one the render folded -- so the causal_parents recorded here are
        # exactly the messages this turn's prompt contained, by construction. A
        # message that arrived during the round trip is NOT in the snapshot and
        # stays pending for the next turn's capture (see #step).
        @timeline = @timeline.commit(role: :assistant, content: response.content, causal_parents: inbox.folded)
        # Commit BEFORE the token check: a turn that busts the ceiling was still
        # paid for, so it stays in the record -- Timeline and Journal both --
        # rather than vanishing with the raise.
        @budget.check_tokens!(@accounting.observe(response, digest: @timeline.head_digest))
      end
    end

    # Fire the machine event named for the (already-normalized) stop_reason and
    # let the machine, not a `case`, decide the resulting state. `StopReason.normalize`
    # (see response.rb) has closed the wire's open enum to StopReason::ALL before
    # we get here, and {LoopMachine} declares one event per member, so the send
    # always names a real event -- a genuinely unrecognized wire value is already
    # :unknown, which fails to :failed. The only loud arm left is structural:
    # firing a reason's event from an illegal state raises
    # StateMachines::InvalidTransition (gate 6). Coupling the event names to
    # StopReason's vocabulary is deliberate; the totality spec pins it.
    #
    # Fire the event, then SETTLE the run-context side effects keyed off the
    # state the machine just reached -- the machine owns the state, the Agent
    # owns the mutable run context. A paused turn needs nothing: it stays in
    # :awaiting_model and re-dispatches, counting against max_iterations so a
    # provider that pauses forever still stops.
    #
    # @return [Symbol] :settled when the loop is finished, :continue otherwise
    def transition(response)
      __send__(:"#{response.stop_reason}!")
      perform_tools(response) if awaiting_tools?
      @failure_reason = FAILURE_REASONS[response.stop_reason] if failed?
      done? || failed? ? :settled : :continue
    end

    # The override resolves HERE, before {ModelCaller}'s middleware phase, and
    # this file alone owns that decision: middleware and provider both see the
    # edited Request as an ordinary one, so ModelCaller stays untouched. The
    # render rides a callable, so an overridden dispatch never invokes
    # `Context#render` at all -- the edit bypasses the pure function instead of
    # traveling through its inputs (T4's design constraint) -- and {RequestOverride#deliver}
    # owns the one-shot's fine print: consumed on success, restored on a raise
    # so a retry re-sends the edit.
    def call_model(on_stream_started)
      dispatch!
      @request_override.deliver(render: -> { render_request }) do |request|
        @model_caller.call(request, on_stream_started:)
      end
    end

    # Compose the sent-not-stored Workspace with the session's live reminders per
    # render: same-args-same-bytes still holds, but the args now vary with session
    # state. Session stays ignorant of Workspace; Workspace stays frozen.
    #
    # The Context itself is asked for per turn rather than read from `@context`,
    # because a strategy that must re-decide every turn (compaction) has no other
    # place to stand -- see {PipelineSource}, whose Null default answers
    # `@context` and makes this line byte-identical to what it replaced. `usage`
    # is Accounting's LAST-turn reading, never its cumulative `#usage`: cumulative
    # input tokens only ever grow, so a window detector fed them latches on and
    # never clears.
    def render_request
      turn_context = @instrumentation.pipeline_source.context_for(base: @context, timeline: @timeline,
                                                                  usage: @accounting.last_turn_usage,
                                                                  session: @session)
      turn_context.render(timeline: @timeline, toolset: @toolset, workspace: @workspace.with(*@session.reminders))
    end

    # Correctness gate 2: every tool_result for one assistant turn goes back in
    # ONE user message. Splitting them across messages silently teaches Claude to
    # stop making parallel tool calls -- a regression with no error attached. The
    # `tool_use` event has already fired (in #transition); this only commits.
    #
    # The workspace snapshot rides HERE, not in #commit_and_account: the
    # assistant-turn commit happens BEFORE the tools run, so this commit is the
    # earliest point where both halves of the snapshot exist -- the written
    # bytes on disk and the turn digest the event names as its cause. It runs
    # AFTER the commit (backward causality, ask_human's idiom) and OUTSIDE the
    # defer_stop atom on purpose: disk is the source of truth a lost snapshot
    # is re-derived from on the next mutating turn, so unlike a TurnUsage
    # record it needs no cancellation shield -- and file IO stays out of the
    # uninterruptible region's heartbeat budget.
    # The delivery is {ToolRunner#delivery}'s value -- the result blocks plus
    # the consumption edges an answered ask_human question rides (I6). The
    # role stays HERE: one USER message holding every result is this class's
    # statement about the Timeline, exactly as before.
    def perform_tools(response)
      @timeline = @timeline.commit(role: :user, **@tool_runner.delivery(response, context: @session))
      @snapshot_writer.write(timeline: @timeline, paths: @session.writes)
    end
  end
end
