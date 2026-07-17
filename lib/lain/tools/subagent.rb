# frozen_string_literal: true

module Lain
  module Tools
    # A one-shot subagent, as an ordinary tool: possessing it is the authorization
    # to spawn a child Agent whose only trace in the parent's Timeline is its
    # final result, returned as an ordinary `tool_result` (gate 2).
    #
    # A subagent is a tool whose result is a compressed context. The child runs a
    # full, independent loop over the SHARED Store but a SEPARATE Timeline, so the
    # parent's prompt never inherits the child's turns and vice versa. Two events
    # record the causal lineage the render chain deliberately omits (event-schema
    # OM-2): a **:spawn** event names the parent head H it was spawned from, and a
    # **:message** event carries the child's result back, naming both the :spawn
    # and the child's final turn F among its causal parents. Neither is in either
    # render chain, so `meet`, the first-parent walk, and gate 2 are untouched.
    #
    # == Injection (the pinned seam)
    #
    # The tool takes its collaborators by CONSTRUCTOR injection at toolset-build
    # time -- provider, a child-Context factory, the union toolset it attenuates
    # from, the spawn {Tool::SpawnPolicy}, a journal, a Budget, and a spawn-depth
    # ceiling. The dispatch duck stays the Session (the `context:` a tool
    # receives), which this tool does not read: everything it needs to spawn was
    # injected, so the ToolRunner and the Session interface are untouched.
    # `parent:` is a live handle to the parent Timeline (a Timeline or a
    # `-> Timeline` thunk, since the toolset is built before the Agent) -- the one
    # collaborator the render chain cannot supply, because H is the parent's head
    # at the instant of the call. The shared Store rides ON that handle
    # (`parent.store`): H, F, and both events live in one content-addressed
    # forest, so deriving it from the parent is one source of truth rather than a
    # separately-injected reference that could silently desync.
    #
    # == The depth ceiling
    #
    # Recursion (a child holding a subagent tool) has no natural floor, so
    # `max_depth` is a hard ceiling: at 0 the tool refuses to spawn (an is_error
    # result), emitting no event and touching no Store. The ceiling is
    # TRANSITIVE by construction: when a child's union is built, every Subagent
    # reachable in it is REPLACED by a copy whose ceiling is
    # `min(its own, this one - 1)` (see {#child_union}) -- decrementing so the
    # chain terminates, `min` so a descendant's own tighter ceiling is never
    # RAISED by the copy (that would be capability escalation). No Budget
    # change: the ceiling is a property of the tool, not of the loop.
    class Subagent < Tool
      # The model-facing input: just the task. The prefix strategy, attenuation
      # posture, and `only`-set are the ARM (config), fixed at construction --
      # "what can this subagent do" stays one readable line, not a per-call
      # decision the model negotiates.
      class Input < Tool::Input
        field :prompt, :string, required: true,
                                description: "The task for the subagent to carry out on its own."
      end

      input_model Input

      # The lifecycle axis (OM-2 vs OM-3), closed and loud: a mode outside this
      # set raises at construction rather than defaulting.
      MODES = %i[one_shot actor].freeze

      # The most recent spawn's records, exposed for observability: the study
      # bench reads the orchestration events, and a one-shot call is synchronous,
      # so the last :spawn/:message events and the child's final Timeline are the
      # honest projection of what the call did. `nil` until a spawn happens (and
      # after a depth refusal, which emits nothing).
      #
      # OM-2-ONLY statefulness (T19 panel #4): `@parent` (a live handle) and
      # these `@last_*` ivars are safe here because a Subagent instance belongs
      # to exactly one agent's toolset and a one-shot spawn runs synchronously
      # inside a single tool dispatch -- no interleaving writer can exist.
      # Returning the records along the call path instead is not cheap today:
      # {Tool::Result} content is pinned to String/Array wire blocks. The actor
      # mode (OM-3) must NOT inherit this shape -- concurrent children would
      # race these ivars, so the actor card should carry its records on events
      # (its mailbox projection), not on tool state.
      attr_reader :name, :last_spawn, :last_message, :last_child

      # Two lifecycle modes over the same spawn machinery (OM-2/OM-3): `:one_shot`
      # runs a child to a single result within one dispatch (the 5-1 model);
      # `:actor` launches a long-lived {Actor} fiber whose outputs reach the
      # parent as mailbox events instead. `log` is the append-only read-side that
      # {Lineage} writes every event to -- the actor's mailbox folds it; the
      # one-shot defaults to {Log::Null} because nothing folds its stream.
      # `observer` is Lineage's outward slot (T13), forwarded verbatim: the
      # session scribe can only attach at THIS constructor, the one seam the exe
      # wires, so an unforwardable observer would be silent record loss one
      # level up.
      def initialize(provider:, context_factory:, toolset:, policy:, parent:,
                     journal: Channel::Null.instance, budget: Agent::Budget.new,
                     max_depth: 1, name: "subagent", mode: :one_shot, log: Log::Null,
                     observer: Event::ChainWriter::Null.new)
        super()
        @provider = provider
        @context_factory = context_factory
        @toolset = toolset
        @policy = policy
        @parent = parent
        @journal = journal
        @budget = budget
        @observer = observer
        seed_config(max_depth, name, mode, log)
      end

      def description
        "Spawns a subagent to carry out `prompt` on its own, with its own tools " \
          "and its own conversation, and returns only its final answer. Use it to " \
          "fan out a self-contained subtask without spending your context on the " \
          "steps it takes to get there."
      end

      # A spawn is safe to run concurrently with its siblings: each child runs a
      # SEPARATE Timeline over the SHARED, Monitor-guarded, content-addressed
      # Store, so parallel commits neither race nor reorder gate 2 (which orders
      # the parent's returned blocks, not Store insertion). This is what lets the
      # {Agent::ToolRunner} fan a turn of subagent calls out as sibling tasks --
      # the async-fan-out win (5-1.4). The spawn path itself is re-entrant: see
      # {#perform}, which threads the spawn's records through LOCALS, never the
      # `@last_*` observability ivars, across the child's IO yield point.
      def parallel_safe? = true

      # Launch a long-lived {Actor} over a freshly built child, and return the
      # handle -- the orchestration seam a supervisor uses to `tell`/`stop` it
      # and read its Timeline. Programmatic ONLY: the fiber spawns on the
      # current task, so the caller must hold a reactor that outlives the
      # parent's asks (an orchestration Sync/Async above the Agent). {#perform}
      # never routes here -- a tool-dispatched actor is refused (see there).
      def launch_actor(prompt, parent: parent_timeline)
        # Per launch, mirroring #perform: AC4's floor note has no lifecycle
        # exemption, so an actor-mode sibling under the floor is reported too.
        @policy.prefix.journal_floor(@journal)
        Actor.new(agent: build_child(parent), lineage:, parent:, journal: @journal).launch(prompt)
      end

      protected

      # A model-dispatched `:actor` is REFUSED, never launched (T23 panel #1):
      # Agent#ask's per-call Sync owns any fiber a tool dispatch spawns, so a
      # perform-launched actor would park as ask's own child and structured
      # concurrency would never let ask return -- the loop wedges, outer
      # reactor or not. Until the OM-6 supervisor provides an orchestration
      # reactor above the Agent, the actor seam is programmatic only
      # ({#launch_actor}); like the depth cap, the refusal emits no event and
      # touches no Store.
      #
      # The one-shot path is re-entrant by construction (5-1.4): the spawn's
      # records ride LOCALS, never the `@last_*` ivars, across `run_child`'s IO
      # yield -- so a sibling fan-out task resuming mid-flight cannot make
      # `message` name the wrong spawn or child. The ivars are written once at
      # the end, together (#remember), a single atomic burst with no yield
      # between the three, so the observability projection stays mutually
      # consistent under concurrency and exact under a one-shot call.
      def perform(input, _invocation)
        return depth_exceeded if @max_depth <= 0
        return actor_refused if @mode == :actor

        # Per spawn, not per tool: the floor note (see PrefixStrategy::
        # SiblingTemplate#journal_floor) lands beside each :spawn it warns
        # about, so a fan-out's record shows which spawns ran un-cacheable.
        @policy.prefix.journal_floor(@journal)
        parent = parent_timeline
        spawn = lineage.spawn(parent)
        child, response = run_child(input.prompt, parent)
        message = lineage.message(parent, spawn, child, response)
        remember(spawn, child, message)
        Tool::Result.ok(response.text)
      end

      # A nested copy of this tool, for a child's union: same collaborators, but
      # the parent handle points at the CHILD (the grandchild's lineage names the
      # child's head, not this parent's) and the ceiling is capped at `ceiling`
      # -- never raised past this tool's own, so a tool wired to never spawn
      # (max_depth 0) stays that way whatever the spawner had left. Protected:
      # only another Subagent, building its child's union, may ask for it.
      def descend(parent:, ceiling:)
        self.class.new(
          provider: @provider, context_factory: @context_factory, toolset: @toolset,
          policy: @policy, parent:, journal: @journal, budget: @budget,
          # The observer descends with the copy: a grandchild's :spawn/:message
          # events must reach the same scribe, or nested spawns silently vanish
          # from the session record -- the failure class this seam closes.
          max_depth: [@max_depth, ceiling].min, name: @name, mode: @mode, log: @log, observer: @observer
        )
      end

      private

      # The observability write, kept apart from #perform so the spawn path reads
      # as pure locals: this is the ONE place the `@last_*` ivars are set, all at
      # once with no yield between, so a reader never sees a half-updated record.
      def remember(spawn, child, message)
        @last_spawn = spawn
        @last_child = child
        @last_message = message
      end

      # A fresh child Agent over the base Timeline the prefix strategy chose,
      # rendering the toolset the posture chose, enforced by the handler the
      # posture chose. `ask` seeds the prompt as the child's first user turn and
      # drives its loop to settle -- fresh starts that turn as a root, inherit
      # starts it on the parent's head (O(1) fork).
      def run_child(prompt, parent)
        child = build_child(parent)
        response = child.ask(prompt)
        [child.timeline, response]
      end

      # `child` is late-bound through the thunk EXACTLY as the exe wires this
      # tool itself: the union must exist before the Agent, but a grandchild's
      # lineage must name the child's LIVE head at its own spawn instant. The
      # `tap` is forced: the obvious `child = spawn_agent(...); child` trips
      # Style/RedundantAssignment, whose "correction" would delete the very
      # assignment the thunk's binding depends on -- the Timeline#commit story
      # again, so the code is shaped to give the cop nothing to break.
      def build_child(parent)
        child = nil
        union = child_union(-> { child.timeline })
        spawn_agent(parent, union, @policy.attenuate(union)).tap { |agent| child = agent }
      end

      # The child's union: the injected one, with every Subagent in it replaced
      # by a {#descend}ed copy -- the transitive-ceiling fix (T19 panel). Handing
      # the SAME instances down would let a nested spawn keep this tool's own
      # undecremented ceiling, and recursion would never terminate via the cap.
      # The copy's schema bytes are identical (same name/description/input), so
      # the rendered tools block -- and with it the cache prefix -- is unchanged.
      def child_union(parent_handle)
        ceiling = @max_depth - 1
        Toolset.new(@toolset.map do |tool|
          tool.is_a?(Subagent) ? tool.descend(parent: parent_handle, ceiling:) : tool
        end)
      end

      # A fresh {Session} per spawn -- never {Session::Null} -- so a
      # write-capable child (read_file + edit_file in its `only`-set) can
      # satisfy EditFile's read-before-write contract against its OWN
      # read-set. Built here, not memoized on `self`: a Subagent instance is
      # reused across sibling spawns (T19's re-entrancy contract), so a
      # per-tool ivar would leak one sibling's reads into the next. `Session.new`
      # never sees the parent's Session -- this tool was never handed a
      # reference to it -- so the child's read-set starts empty by construction.
      # The prefix strategy shapes the factory's product (`sibling_template`
      # appends its shared template as the marked-by-Context system tail; the
      # other arms pass it through), so template threading rides the SAME
      # injected-factory seam the exe already wires. The journal rides along
      # so a strategy that rewrites the factory's system (a stripped caller
      # mark) can say so in the record.
      def spawn_agent(parent, union, allowed)
        Agent.new(
          provider: @provider, context: @policy.prefix.child_context(@context_factory.call, journal: @journal),
          toolset: @policy.posture.rendered_toolset(union:, allowed:), handler: child_handler(union, allowed),
          timeline: @policy.prefix.base_timeline(parent:, store: parent.store),
          session: Session.new, budget: @budget, journal: @journal
        )
      end

      # `schema` renders the attenuated set, so a plain executor over it suffices;
      # `handler_union` renders the shared union, so the RefusingHandler enforces
      # the `only`-set the model can now see but must not use. Both dispatch
      # against the DESCENDED union, never `@toolset`, so a permitted nested
      # subagent runs at its decremented ceiling.
      def child_handler(union, allowed)
        return Effect::Handler::Live.new(toolset: allowed) unless @policy.posture.refuses_over_union?

        RefusingHandler.new(allowed: allowed.names, journal: @journal,
                            inner: Effect::Handler::Live.new(toolset: union))
      end

      # The spawn's event record, delegated: {Lineage} writes the :spawn and
      # :message events (see that class for the causal-edge and correlation-
      # join reasoning). Memoized here, not built in #initialize, only to keep
      # the wiring point within its Metrics budget -- Lineage is pure over the
      # frozen @policy, so late construction changes nothing.
      def lineage = @lineage ||= Lineage.new(policy: @policy, log: @log, observer: @observer)

      # The config axis, apart from the injected collaborators (the Agent
      # `seed_run_state` split). Mode fails loudly here -- a mistyped mode must
      # not silently fall through to one-shot (unknown values raise, per the
      # loud-failure premise the CLAUDE notes pin), not default.
      def seed_config(max_depth, name, mode, log)
        @max_depth = Integer(max_depth)
        @name = name
        @mode = MODES.include?(mode.to_sym) ? mode.to_sym : raise(ArgumentError, "bad subagent mode #{mode.inspect}")
        @log = log
      end

      def depth_exceeded = Tool::Result.error("subagent spawn depth exceeded: this agent is at the ceiling")

      def actor_refused
        Tool::Result.error("actor mode cannot be launched from a tool call: a long-lived actor needs " \
                           "the OM-6 supervisor reactor; launch it programmatically via #launch_actor")
      end

      # The parent Timeline, live: a Timeline passes through, a thunk is called
      # (the toolset is built before the Agent, so the exe wiring hands a
      # `-> { agent.timeline }` that reads the head at the instant of the call).
      def parent_timeline
        @parent.respond_to?(:call) ? @parent.call : @parent
      end
    end
  end
end

# These children reopen Subagent (and RefusingHandler subclasses Effect::Handler,
# long loaded by the time tools.rb requires this unit), so they load after the
# class body -- subagent.rb is this subtree's index, the effect/handler.rb
# convention. Log leads: Lineage's `log:` default names Log::Null.
require_relative "subagent/log"
require_relative "subagent/lineage"
require_relative "subagent/refusing_handler"
require_relative "subagent/actor"
