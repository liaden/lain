# frozen_string_literal: true

require "async"
require "monitor"
require "state_machines"
require "active_support/core_ext/module/delegation"

require_relative "agent/accounting"
require_relative "agent/budget"
require_relative "agent/instrumentation"
require_relative "agent/loop_machine"
require_relative "agent/model_caller"
require_relative "agent/pipeline_source"
require_relative "agent/request_override"
require_relative "agent/snapshot_slot"
require_relative "agent/stop_reason"
require_relative "agent/tool_delivery"
require_relative "agent/tool_runner"
require_relative "agent/transition_listener"

module Lain
  # The loop, written as an explicit state machine rather than a while-loop over
  # a `case`.
  #
  # Every `stop_reason` the wire can carry must have somewhere to go, and a
  # `case` with no `else` is how a new enum value -- or a forgotten old one like
  # `:stop_sequence` -- becomes a turn that silently does nothing. Here each
  # reason is a named transition and {::Lain::StopReason::UNKNOWN} is a real
  # destination, so an unrecognized value fails loudly rather than falling
  # through.
  #
  # The Agent owns the loop. Both SDKs offered to own it (`tool_runner`,
  # `Chat#complete`) and both were declined, because the loop is what this
  # project exists to study.
  class Agent
    # States, legal transitions and the journaling seam; also defines {STATES}.
    include LoopMachine

    # The settled half of {STATES}. `:stalled` and `:awaiting_approval` are
    # deliberately absent -- both are mid-run PARKS that a run resumes from.
    #
    # Homed here rather than at its reader ({CLI::ResendBridge}) because it had
    # been defined in two places, byte-identical and cross-referenced from
    # neither, over a machine that can gain a state.
    QUIESCENT = %i[awaiting_user done failed].freeze

    # Kept for callers that rescue the harness's own halt. See Agent::Budget.
    BudgetExceeded = Budget::Exceeded

    # A rewind asked of an Agent whose run someone else holds. That run settles
    # onto the Timeline it captured and hands it back, so a head moved under it
    # is committed over the moment it lands.
    class InFlight < Error; end

    IN_FLIGHT = "cannot rewind while a run is in flight: it would commit its turns over the rewound head"
    private_constant :IN_FLIGHT

    # {#ask}'s default fold observer: an Agent with no record to keep has
    # nothing to do when it folds.
    NO_FOLD = ->(_stranded, _folded) {}
    private_constant :NO_FOLD

    # The diagnostic each failing stop_reason records. A lookup table, not control
    # flow: every wire stop reason whose event transitions to :failed has an
    # entry. Root-qualified because {Agent::StopReason} shadows the wire enum
    # everywhere inside this class.
    FAILURE_REASONS = { ::Lain::StopReason::MAX_TOKENS => "model hit max_tokens before finishing",
                        ::Lain::StopReason::REFUSAL => "model refused to continue",
                        ::Lain::StopReason::UNKNOWN => "unrecognized stop_reason from provider" }.freeze
    private_constant :FAILURE_REASONS

    # Each of the three objects the loop drives, paired with the legacy
    # keywords that BUILD it when it is not injected: the clash table
    # {#refuse_double_wiring} consults. Four of these are {Instrumentation}
    # members too, so their DEFAULTS come from that value; they stay named here
    # because the clash rule is keyed on what a caller actually wrote.
    INGREDIENTS = { model_caller: %i[provider model_middleware],
                    tool_runner: %i[handler tool_middleware tool_observer],
                    accounting: %i[journal] }.freeze

    # The ingredient vocabulary, flat. Public because {#initialize} splits its
    # own `**instrumented` splat on it, and because {Instrumentation.resolve}
    # names the half it does not own from it -- one list, so the two refusals
    # can never quote different keywords.
    KEYWORDS = INGREDIENTS.values.flatten.freeze

    # "No keyword was written here" -- which `nil` cannot say, because an
    # explicit nil is a caller MISTAKE this class refuses
    # ({#refuse_explicit_nil}). A bare frozen object, so nothing a caller could
    # plausibly pass collides with it. It never escapes the constructor.
    OMITTED = Object.new.freeze

    MISSING_PROVIDER = "no provider: and no model_caller: -- the Agent needs something to call. Pass either the " \
                       "provider (and a ModelCaller gets built over it) or a ModelCaller of your own."
    private_constant :MISSING_PROVIDER

    # `request_override` is public on purpose: {CLI::ResendBridge} queues an
    # edited Request through this reader rather than threading its own handle
    # through construction.
    attr_reader :timeline, :toolset, :context, :workspace, :session,
                :iterations, :failure_reason, :budget, :request_override, :dispatch_lock

    delegate :usage, to: :accounting

    # Private because every caller is one: the curated public surface above is
    # this class's own decision to widen, and the three objects the loop drives
    # are not part of it.
    attr_reader :model_caller, :tool_runner, :accounting
    private :model_caller, :tool_runner, :accounting

    # The Agent is the wiring point of the whole harness, and the honest split
    # is three-way: values that are ALREADY their own collaborators ({Budget},
    # {Instrumentation}); the collaborators the loop drives; and the mutable run
    # state it seeds ({#seed_run_state}). A `Wiring` value object grouping the
    # collaborators was rejected -- it would not remove `seed_run_state` (run
    # state is orthogonal to collaborators), and it would move a public keyword
    # surface the `provider_parity` shared group and the state-machine specs
    # construct against by name, for no reduction in moving parts.
    #
    # Each of the three objects the loop drives may be handed over WHOLE
    # (`model_caller:`, `tool_runner:`, `accounting:`) or as the INGREDIENTS it
    # is built from (`provider:`, `handler:`, `journal:` and their middleware),
    # which is what every caller did before they were injectable. The styles
    # compose ACROSS collaborators -- an injected ToolRunner beside a
    # `provider:` says nothing contradictory -- and mixing them for ONE
    # collaborator raises ({#refuse_double_wiring}). {Instrumentation.resolve}
    # owns the same rule for the seven keywords a run REPORTS through, still
    # accepted through `**instrumented`.
    #
    # The refusals fire in a FIXED order -- instrumentation's vocabulary, then
    # explicit nil, then double wiring, then a foreign toolset -- so a call with
    # two mistakes always reports the same one: vocabulary first (a typo makes
    # every later question meaningless), then the values, then what the values
    # mean together. `MISSING_PROVIDER` is the exception, firing lazily while
    # the ModelCaller is built, between the last two.
    #
    # Collaborator keywords default to {OMITTED} rather than to their values
    # because resolution has to tell "not written" from "written", and `nil`
    # cannot serve: an explicit `nil` is a caller mistake {#refuse_explicit_nil}
    # refuses rather than reads as a default. The marker never escapes this
    # constructor.
    #
    # @param toolset [Lain::Toolset] the run's capability set, rendered into
    #   every Request and shared with `tool_runner:` -- construction is refused
    #   if the two disagree ({ToolRunner.refuse_foreign_toolset}).
    # @param context [Lain::Context] the base rendering strategy, `(Timeline,
    #   Toolset, Workspace) -> Request`. Asked for per turn through
    #   `instrumentation.pipeline_source`, so a strategy that must re-decide
    #   every turn (compaction) has somewhere to stand.
    # @param instrumentation [Instrumentation] where this run's records, phases
    #   and observers go. Defaults to the all-Null value: a run that reports
    #   nowhere.
    # @param model_caller [ModelCaller] the run's ModelCaller, handed over WHOLE
    #   rather than built from `provider:`/`model_middleware:`.
    # @param provider [Provider] the raw provider a ModelCaller gets built over
    #   when `model_caller:` is not written -- the INGREDIENT half of that same
    #   collaborator.
    # @param tool_runner [ToolRunner] the run's ToolRunner, handed over WHOLE
    #   rather than built from `handler:`/`tool_middleware:`/`tool_observer:`.
    # @param handler [Effect::Handler] the tool-effect interpreter a ToolRunner
    #   gets built over when `tool_runner:` is not written.
    # @param accounting [Agent::Accounting] the run's token roll-up, handed over
    #   WHOLE rather than built from `journal:`.
    # @param timeline [Timeline, nil] the run's causal history. `nil` builds an
    #   empty Timeline over a fresh {Store}; a caller resuming a session hands
    #   one in.
    # @param workspace [Workspace] the sent-not-stored files/tools context
    #   rendered into every Request. Frozen, and never appended to the Timeline.
    # @param session [Session] the run's mutable scratch state (files read, the
    #   todo list) -- deliberately off the Timeline, so forking or rewinding can
    #   never resurrect or lose one.
    # @param mailbox [Context::Mailbox] pending actor messages folded into the
    #   rendered tail. Defaults to the Null combinator, which folds nothing.
    # @param budget [Budget] the ceilings that bound this autonomous loop; a
    #   budget stop is the harness deciding to halt, not a model outcome.
    # @param request_override [RequestOverride] the one-shot slot a frontend
    #   resend queues an edited Request into; the next dispatch sends it
    #   byte-identically and the slot empties itself.
    # @param context_window [#occupancy] the book {#occupancy} measures against.
    #   Constructor state rather than a per-call default because the one caller
    #   that renders the figure to a human ({Frontend::PromptComposer::RunState})
    #   calls `#occupancy` with no keyword: a per-call default left the REPL
    #   prompt dividing by {ContextWindow::CONSERVATIVE_FALLBACK} while the state
    #   feed divided by the served window, and two surfaces disagreeing about one
    #   turn is worse than both being uniformly wrong.
    # @param snapshot_slot [SnapshotSlot] holds the writer that captures which
    #   files a turn's tools wrote, as a causal-only Store event; a read-only
    #   turn lands nothing. A slot rather than a writer, so a posture flip can
    #   change the writer under a delivery built once.
    # @param instrumented [Hash{Symbol => Object}] the seven keywords a run
    #   REPORTS through (`turn_middleware:`, `transition_listener:`, etc.),
    #   accepted directly so every call site that predates `instrumentation:`
    #   keeps its meaning. Writing both raises.
    def initialize(toolset:, context:, instrumentation: OMITTED,
                   model_caller: OMITTED, provider: OMITTED,
                   tool_runner: OMITTED, handler: OMITTED,
                   accounting: OMITTED, timeline: nil, workspace: Workspace.empty,
                   session: Session.new, mailbox: Context::Mailbox::Null,
                   budget: Budget.new, request_override: RequestOverride::None,
                   snapshot_slot: SnapshotSlot.new, context_window: ContextWindow.default,
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
      seed_run_state(session, snapshot_slot, budget)
    end

    # Append a user turn and run until the loop settles.
    #
    # A new user turn reopens a settled loop, so asking again after `:done` or
    # `:failed` continues the conversation rather than raising on `dispatch!`
    # from a terminal state. The guard keeps the first `ask` transition-free.
    #
    # `on_stream_started` is the first-token observer ({Tools::Subagent::Stagger}
    # hands each child Agent one to signal the stagger gate). Nil is INERT: the
    # whole plumb down to the provider is byte-identical with no observer wired.
    #
    # A head still carrying an unanswered `tool_use` is answered BEFORE the new
    # text lands, the in-process twin of {CLI::Resume}'s repair at load and in
    # its words: nothing here can say whether that call ran. Text committed on
    # top of an orphan is a chain every later request and derivation refuses.
    #
    # A prompt no model can have seen -- refused whole for not fitting its
    # context ({Lain::WindowExceeded}), or failed before any attempt wrote a
    # byte ({Lain::PreWire}) -- is WITHDRAWN: the head goes back to where it
    # stood before this ask's text, and a re-sent prompt does not stack on a
    # turn nothing answered. The Timeline stays lossless -- the turn is still in
    # the Store -- and only while that text is still the head: a tool round
    # that ran before a later refusal in the same ask is work that happened, and
    # stays. The error is told, so its words can say which it was.
    #
    # Any other failure may have reached a model, so its prompt stays, STRANDED.
    # The next ask folds the stranded text and the new text into one user turn
    # cut from the stranded turn's parent, rather than stacking a second
    # unanswered prompt on it. The shape decides, not what left the prompt
    # there: a stop, a failed resend and a /rewind onto a prompt leave the same
    # head, and the model reads the same text either way.
    #
    # @param text [String] the prompt
    # @param on_stream_started [#call, nil] the first-token observer
    # @param on_fold [#call] told `(stranded, folded)` -- the chain before the
    #   fold and the chain after it -- under the dispatch lock and before the
    #   request is sent, so a caller keeping a record can make the folded turn
    #   durable ahead of the wire
    # @return [Lain::Response] the final assistant response
    # @raise [Tool::Cancellation::Unpairable] when the stranded call names no
    #   id, so nothing can answer it and nothing is committed over it
    def ask(text, on_stream_started: nil, on_fold: NO_FOLD)
      @dispatch_lock.synchronize do
        reopen! unless awaiting_user?
        answer_stranded(:unknown)
        before = @timeline
        @timeline = asked = prompted([{ "type" => "text", "text" => text }], on_fold)
        withdrawing(before, asked) { run(on_stream_started:) }
      end
    end

    # Drive the machine from its current Timeline. Separated from {#ask} so a
    # rewound or forked Timeline can be resumed without inventing a user turn.
    #
    # The turn phase's env carries `iteration` -- turns already committed IN
    # THIS RUN, restarting at 0 per #run because the ceiling it feeds bounds one
    # autonomous loop and not a conversation (see #run_loop). A middleware
    # watching two asks of two turns each therefore sees 0, 1, 0, 1; anything
    # wanting a per-conversation reading has to count for itself, off the
    # Timeline. `timeline` is the Timeline as of the START of this turn, before
    # this turn's own commit lands.
    #
    # `Sync` is what puts the loop inside a fiber reactor, so its IO (the
    # provider round trip, a `bash` shellout) yields to the scheduler and a
    # {Budget#interrupt} lands as structured cancellation at those yield points.
    # It joins the caller's reactor when there is one and spins one up when
    # there is not, which is why every non-reactor caller is unchanged.
    #
    # `@dispatch_lock` makes a run EXCLUSIVE, and is reentrant (a Monitor) so
    # `#ask` -> `#run` holds it once. It exists for bridged resends:
    # {CLI::ResendBridge} runs on the Neovim resend-worker thread while a user
    # prompt runs `#ask` on the conductor's reactor, both driving THIS agent's
    # bare-ivar state, so the bridge's quiescence gate would otherwise be a
    # check-then-act race across the two.
    def run(on_stream_started: nil) = @dispatch_lock.synchronize { Sync { run_loop(on_stream_started) } }

    # Is a dispatch in flight RIGHT NOW? A different question from {#state},
    # which records what the loop was last doing. The two disagree exactly when
    # a turn is TORN: {#reopen!} fires at the start of the next {#ask}, so a run
    # that raised out leaves the machine parked at `:awaiting_model` indefinitely
    # while nothing runs. `Monitor#synchronize` releases on the way out of a
    # raise, so the lock does not lie about that.
    #
    # A snapshot, not a reservation: a caller needing the answer to STAY true
    # must hold the lock itself ({CLI::ResendBridge} does, with `try_enter`).
    def dispatching? = @dispatch_lock.mon_locked?

    # `#done?` and `#failed?` are generated by the state machine, one predicate
    # per state, so they cannot disagree with the declared state set.

    # How full the context is right now, as a fraction of the live model's
    # window: 0.5 is half spoken for.
    #
    # The numerator is {Accounting}'s LAST-turn input tokens, never its
    # cumulative `#usage` -- a cumulative sum only ever grows, so it would report
    # a context that never empties even after a compaction dropped the head --
    # and only while this chain still holds the turn that reading stood on.
    # `context.model` is read per call rather than captured, so a mid-session
    # `/model` switch ({Context::ModelSwitch}) moves the denominator with it.
    #
    # This and {Compaction::Source} must ask the SAME book or a status line and
    # the compaction trigger tell a user two different stories. Both take one at
    # CONSTRUCTION, and a live chat hands both the same instance, so they cannot
    # come apart -- which they could while this defaulted per call and a wiring
    # swapped only the Source's.
    #
    # @param context_window [#occupancy] the window book, defaulting to the one
    #   this Agent was CONSTRUCTED with. Written explicitly only by a caller
    #   measuring a run against a window that is not the run's own -- a bench
    #   arm sweeping candidate windows.
    # @return [Float, nil] nil before any turn, and after a rewind past the
    #   reading -- absence, not an empty context
    # @raise [ContextWindow::UnknownModel] if the live model slot is nil or
    #   blank (a wiring bug), or if the model matches nothing in a book
    #   configured with no fallback. A caller rendering this per prompt either
    #   guarantees a model or rescues.
    # @raise [ArgumentError] if the book answers a non-positive window, which
    #   measures as Infinity or NaN rather than as a reading. Unreachable
    #   through {ContextWindow.default}; a caller passing its own book owns it.
    def occupancy(context_window: @context_window)
      context_window.occupancy(accounting.last_turn_usage(on: @timeline), model: context.model).ratio
    end

    # Time travel: the loop can be resumed from any earlier turn, which is what
    # makes speculative branching possible once a grader exists.
    #
    # Refused while a run this caller does not hold is in flight, and the lock
    # is HELD for the move rather than read before it, so no run can start
    # between the check and the act. The caller that already holds it is let
    # through, because the lock is reentrant: {CLI::ResendBridge} rewinds from
    # inside the very lock that makes its own run exclusive.
    #
    # The Session is told where the chain now stands, and it is the only thing
    # told: this object stays memory-blind: it never names a {Memory::Index} or
    # a {Memory::Recorder}, and what the Session does with the move -- retire
    # reads the chain no longer carries, drop a memory the rewind went past --
    # is the Session's own business. Inside the lock, so the move and the
    # projections that follow it cannot be split by a run starting between them.
    #
    # @raise [InFlight] while another caller's run holds the dispatch lock
    def rewind(count = 1)
      raise InFlight, IN_FLIGHT unless @dispatch_lock.try_enter

      begin
        @timeline = @timeline.rewind(count)
        @session.rewound_to(@timeline)
        reopen!
        self
      ensure
        @dispatch_lock.exit
      end
    end

    private

    def withdrawing(before, asked)
      yield
    rescue WindowExceeded, PreWire => e
      raise e unless @timeline.equal?(asked)

      @timeline = before
      raise e.withdrawn!
    end

    def prompted(prompt, on_fold)
      head = @timeline.head
      return @timeline.commit(role: :user, content: prompt) unless stranded_prompt?(head)

      @timeline.checkout(head.parent).commit(role: :user, content: head.content + prompt)
               .tap { |folded| on_fold.call(@timeline, folded) }
    end

    # Text a human asked that nothing answered. A head of tool results is not
    # one: folding it would put an answer to the model's calls in the human's
    # mouth.
    def stranded_prompt?(head)
      !head.nil? && head.role == "user" && head.content.all? { |block| block["type"] == "text" }
    end

    # The repair every stranded head gets, through the one mint every repair
    # shares; a head with nothing stranded is left exactly as it is.
    def answer_stranded(kind)
      return unless Event.pending_tool_use?(@timeline.head)

      @timeline = @timeline.commit(role: :user, content: Tool::Cancellation.new(@timeline.head, kind:).blocks)
    end

    # The loop itself, hosted inside the reactor {#run} establishes.
    #
    # The two seeded lines are the state ONE loop owns, and both #ask (a commit
    # plus a run) and a bridged resend (a run with no commit) start counting
    # from zero. Seeding them per AGENT instead made the iteration ceiling a
    # whole-session budget: manual QA measured 25 turns spread over nine
    # separate prompts exhausting it, after which every prompt was committed as
    # a user turn and raised on before the provider was asked -- a session still
    # taking input and no longer able to answer any of it. A conversation-wide
    # ceiling is a different policy needing its own name and refusal
    # ({CLI::GoalDriver::Run} is what one looks like).
    def run_loop(on_stream_started)
      @failure_reason = nil
      @iterations = 0

      loop do
        env = @instrumentation.turn_middleware.call({ iteration: @iterations, timeline: @timeline }) do |inner|
          response = step(on_stream_started)
          inner.merge(response:, settled: transition(response) == :settled)
        end
        return env.fetch(:response) if env.fetch(:settled)
      end
    end

    # {Instrumentation} owns one half of the two-style resolution the
    # constructor describes and {#resolve_collaborators} the other. Both resolve
    # EAGERLY, so a wiring mistake raises here and not on the first turn.
    # `instrumented` reaches the second half too, because four of its members
    # (`journal`, the model and tool phases, the observer) are also ingredients
    # and the clash table is keyed on the keywords a caller actually wrote.
    def wire_callers(request_override:, instrumentation:, instrumented:, **collaborators)
      @instrumentation = Instrumentation.resolve(instrumentation, instrumented)
      resolve_collaborators(**collaborators, **instrumented.slice(*KEYWORDS))
      @request_override = request_override
    end

    # The three objects the loop drives, resolved from either construction
    # style. An unknown keyword never reaches here: every collaborator keyword
    # is NAMED on {#initialize} and therefore policed by Ruby, and everything
    # else is swept into `**instrumented`, whose vocabulary
    # {Instrumentation.refuse_unknown} has already refused.
    def resolve_collaborators(model_caller:, tool_runner:, accounting:, **ingredients)
      refuse_explicit_nil({ model_caller:, tool_runner:, accounting:, **ingredients })
      given = written(ingredients)
      injected = written({ model_caller:, tool_runner:, accounting: })
      refuse_double_wiring(injected, given)
      @model_caller = injected.fetch(:model_caller) { built_model_caller(given) }
      @tool_runner = injected.fetch(:tool_runner) { built_tool_runner(given) }
      @accounting = injected.fetch(:accounting) { built_accounting(given) }
      ToolRunner.refuse_foreign_toolset(@tool_runner, toolset: @toolset)
    end

    # The keys a caller actually wrote. Unlike a `compact`, this keeps an
    # explicit nil visible for the check above.
    def written(wiring) = wiring.reject { |_key, value| OMITTED.equal?(value) }

    # An explicit nil is a mistake, not a request for the default: the way to
    # take a default is to OMIT the keyword. Loud, because every silent reading
    # is worse -- `handler: nil` read as a default becomes a LIVE
    # {Effect::Handler::Live} over the real toolset, a nil that runs tools, and
    # `journal: nil` would discard the experiment record a caller thought they
    # had asked for. cli/tool_guard.rb takes the same position.
    def refuse_explicit_nil(wiring)
      nils = wiring.select { |_key, value| value.nil? }.keys
      return if nils.empty?

      raise ArgumentError, "#{labelled(nils)} was given as nil. Omit the keyword to take the default; nil is " \
                           "not a wiring value, and reading it as one would hide the mistake."
    end

    # Both styles are valid; mixing them for ONE collaborator is not. A caller
    # who hands over a {ModelCaller} *and* a `provider:` has stated two answers
    # to "which provider does this run talk to", and quietly honouring one is
    # how a bench arm measures an arm nobody configured.
    def refuse_double_wiring(injected, given)
      injected.each_key do |collaborator|
        refuse_clash(collaborator, INGREDIENTS.fetch(collaborator) & given.keys)
      end
    end

    def refuse_clash(collaborator, clash)
      return if clash.empty?

      raise ArgumentError, "#{collaborator}: was passed together with #{labelled(clash)}, which is what it " \
                           "would have been BUILT from -- two answers to one wiring question. Pass the " \
                           "collaborator or its ingredients, not both."
    end

    # `given` is the ingredients a caller actually WROTE, threaded as an
    # argument rather than held on an ivar: it is construction-time input, and
    # an Agent that kept it would be carrying dead wiring state for its whole
    # life. `fetch` with a block keeps the Null-Object posture: the default is
    # named at the one place that needs it, so nothing downstream tolerates nil.
    # The four reporting keywords fall back to {Instrumentation}'s members
    # rather than to a Null written here, so there is ONE statement of what a
    # run reports through.
    def built_model_caller(given)
      ModelCaller.new(provider: given.fetch(:provider) { raise ArgumentError, MISSING_PROVIDER },
                      middleware: given.fetch(:model_middleware) { @instrumentation.model_middleware })
    end

    def built_tool_runner(given)
      ToolRunner.new(handler: given.fetch(:handler) { Effect::Handler::Live.new },
                     middleware: given.fetch(:tool_middleware) { @instrumentation.tool_middleware },
                     toolset: @toolset,
                     observer: given.fetch(:tool_observer) { @instrumentation.tool_observer })
    end

    def built_accounting(given) = Accounting.new(journal: given.fetch(:journal) { @instrumentation.journal })

    def labelled(keywords) = keywords.map { |keyword| "#{keyword}:" }.join(", ")

    # The mutable run context, kept apart from #initialize because what is there
    # is immutable wiring. The state machine owns its own state (initial:
    # `:awaiting_user`), so that is not seeded here.
    #
    # The transition listener is the one {Instrumentation} member copied to an
    # ivar, because {LoopMachine} announces through it from a mixin; the turn
    # stack and the per-turn Context source are asked of the value at their
    # single use sites instead.
    #
    # The {Budget} is seeded here rather than beside the collaborators so it
    # sits with the counter it bounds -- `#step` checks it and increments
    # `@iterations` on the next line. The zero is what an Agent that has never
    # run reports; #run_loop re-seeds it per run, the scope the ceiling bounds.
    def seed_run_state(session, snapshot_slot, budget)
      @transition_listener = @instrumentation.transition_listener
      @session = session
      @deliveries = ToolDelivery.new(runner: tool_runner, journal: @instrumentation.journal, snapshots: snapshot_slot)
      @budget = budget
      @iterations = 0
      @dispatch_lock = Monitor.new
    end

    def step(on_stream_started)
      @budget.check_iterations!(@iterations)
      @iterations += 1
      # Snapshotted HERE, before the render, and that one frozen Snapshot is
      # what both the render-side Mailbox fold and this turn's commit consume.
      # The shared log is mutable DURING the provider round trip -- an actor
      # reply can land mid-dispatch -- so neither side may read it live: a live
      # read at commit would claim that arrival as a causal parent of a turn
      # that never rendered it, marking it consumed and losing it. Consumed only
      # by a successful commit, so a raised dispatch re-captures and re-folds.
      inbox = @mailbox.capture(@timeline)
      call_model(on_stream_started).tap { |response| commit_and_account(response, inbox) }
    end

    # The commit, its record and its TurnUsage, shielded as ONE atom against
    # cancellation. `defer_stop` holds a {Budget#interrupt} off until the region
    # exits, so a stop can never land between the Timeline commit and either
    # write: bench cost accounting reads the Journal, and a committed turn whose
    # usage record vanished with an interrupt would silently price as free. The
    # deferred stop also preempts a raise from inside the region, so a
    # simultaneous stop and token-ceiling bust settles as the stop.
    #
    # A failure after the commit -- the token ceiling, or either record
    # refusing to land -- comes before any {ToolDelivery} exists, so the calls
    # this turn just committed are answered here, inside the same shield, and
    # the failure goes on.
    def commit_and_account(response, inbox)
      Async::Task.current.defer_stop do
        # Commit the FULL content -- text, thinking, AND tool_use blocks.
        # Extracting only the text corrupts the very next turn. `inbox` is the
        # frozen Snapshot #step captured at turn start, so the causal_parents
        # recorded here are exactly the messages this turn's prompt contained.
        @timeline = @timeline.commit(role: :assistant, content: response.content, causal_parents: inbox.folded)
        # Commit BEFORE the token check: a turn that busts the ceiling was still
        # paid for, so it stays in the record rather than vanishing with the
        # raise.
        account(response)
      end
    end

    # The turn is settled into the record ahead of its usage, because the usage
    # record and everything the tool round goes on to write -- a memory root, a
    # spawn, a question -- cite it, and a process killed between two of these
    # writes must leave no citation of a turn the file lacks.
    def account(response)
      @instrumentation.turn_middleware.settle(@timeline)
      @budget.check_tokens!(accounting.observe(response, digest: @timeline.head_digest))
    rescue StandardError => e
      answer_errored
      raise e
    end

    # Whatever stops the repair -- an unpairable call, a store refusing this
    # commit too -- leaves the failure being handled in charge, for
    # {ToolDelivery}'s reason. The head is answered at the next ask instead.
    def answer_errored
      answer_stranded(:errored)
    rescue StandardError
      nil
    end

    # Fire the machine event named for the (already-normalized) stop_reason and
    # let the machine, not a `case`, decide the resulting state.
    # `::Lain::StopReason.normalize` has closed the wire's open enum before we get here
    # and {LoopMachine} declares one event per member, so the send always names
    # a real event -- an unrecognized wire value arrives as `:unknown`, which
    # fails to `:failed`. The only loud arm left is structural: firing from an
    # illegal state raises `StateMachines::InvalidTransition`. Coupling the
    # event names to the wire enum's vocabulary is deliberate; a totality spec pins
    # it.
    #
    # The side effects that follow are keyed off the state the machine just
    # reached: the machine owns the state, the Agent owns the run context. A
    # paused turn needs nothing -- it stays in `:awaiting_model` and
    # re-dispatches, counting against max_iterations so a provider that pauses
    # forever still stops.
    #
    # @return [Symbol] :settled when the loop is finished, :continue otherwise
    def transition(response)
      __send__(:"#{response.stop_reason}!")
      perform_tools(response) if awaiting_tools?
      @failure_reason = FAILURE_REASONS[response.stop_reason] if failed?
      done? || failed? ? :settled : :continue
    end

    # The override resolves HERE, before {ModelCaller}'s middleware phase, so
    # middleware and provider both see the edited Request as an ordinary one and
    # ModelCaller stays untouched. The render rides a callable, so an overridden
    # dispatch never invokes `Context#render` at all -- the edit deliberately
    # bypasses the pure function rather than traveling through its inputs.
    # {RequestOverride#deliver} owns the one-shot's fine print: consumed on
    # success, restored on a raise so a retry re-sends the edit.
    #
    # A prompt refused for not fitting the context still leaves its measure:
    # the provider's exact count becomes the reading the next render's
    # compaction decision reads ({Accounting#observe_refusal}). The turn it
    # stands on is named once, here, and rides the model phase so the refusal
    # record carries the same answer to every live view.
    def call_model(on_stream_started)
      dispatch!
      attempt(Event.stands_on(@timeline.head), on_stream_started)
    end

    # ONE retry, and only where a handoff just made room: the refusal carries
    # the provider's exact count, which is the first honest measurement this
    # run has of a prompt that does not fit, and a fallback that could not use
    # it would be a fallback that never fires. A SECOND refusal is the ask
    # failing -- there is nothing further to replace -- and it withdraws and is
    # worded like any other over-window refusal.
    #
    # The retry re-RENDERS rather than re-sending: the handoff committed a cut,
    # and it is the next render through {#render_request} that holds it.
    # {RequestOverride#deliver} restores a consumed one-shot on a raise, so an
    # edited dispatch is re-sent rather than lost here.
    def attempt(stands_on, on_stream_started, fallback: true)
      @request_override.deliver(render: -> { render_request }) do |request|
        model_caller.call(request, on_stream_started:, stands_on:)
      end
    rescue WindowExceeded => e
      accounting.observe_refusal(prompt_tokens: e.prompt_tokens, head: stands_on)
      raise unless fallback && handed_off

      attempt(stands_on, on_stream_started, fallback: false)
    end

    # Asks the run's compaction source for room and answers whether it made
    # any. Past tense and no `?`, because this COMMITS: a handoff cut lands
    # here, and a predicate name would read as a question about state.
    def handed_off = @instrumentation.pipeline_source.handoff(timeline: @timeline, session: @session)

    # Composing the Workspace with the session's live reminders per render keeps
    # same-args-same-bytes; the args simply now vary with session state. Session
    # stays ignorant of Workspace; Workspace stays frozen.
    #
    # The Context is asked for per turn rather than read from `@context` because
    # a strategy that must re-decide every turn (compaction) has nowhere else to
    # stand; {PipelineSource}'s Null default answers `@context`. `usage` is
    # Accounting's LAST-turn reading, never its cumulative `#usage`: cumulative
    # input tokens only ever grow, so a window detector fed them latches on and
    # never clears.
    def render_request
      turn_context = @instrumentation.pipeline_source.context_for(base: @context, timeline: @timeline,
                                                                  usage: accounting.last_turn_usage(on: @timeline),
                                                                  session: @session)
      turn_context.render(timeline: @timeline, toolset: @toolset, workspace: @workspace.with(*@session.reminders))
    end

    # Every tool_result for one assistant turn goes back in ONE user message.
    # Splitting them across messages silently teaches Claude to stop making
    # parallel tool calls -- a regression with no error attached.
    #
    # This class decides WHEN tools run; {ToolDelivery} decides how what they
    # produced lands. The Timeline comes back through the block rather than as a
    # return value because the torn path commits AND re-raises, and a return
    # value would be discarded by the very interrupt the commit exists to
    # survive.
    def perform_tools(response)
      @deliveries.perform(response, timeline: @timeline, session: @session) { |turn| @timeline = turn }
    end
  end
end
