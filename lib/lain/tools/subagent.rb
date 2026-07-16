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

      def initialize(provider:, context_factory:, toolset:, policy:, parent:,
                     journal: Channel::Null.instance, budget: Agent::Budget.new,
                     max_depth: 1, name: "subagent")
        super()
        @provider = provider
        @context_factory = context_factory
        @toolset = toolset
        @policy = policy
        @parent = parent
        @journal = journal
        @budget = budget
        @max_depth = Integer(max_depth)
        @name = name
      end

      def description
        "Spawns a subagent to carry out `prompt` on its own, with its own tools " \
          "and its own conversation, and returns only its final answer. Use it to " \
          "fan out a self-contained subtask without spending your context on the " \
          "steps it takes to get there."
      end

      protected

      def perform(input, _invocation)
        return depth_exceeded if @max_depth <= 0

        parent = parent_timeline
        @last_spawn = lineage.spawn(parent)
        @last_child, response = run_child(input.prompt, parent)
        @last_message = lineage.message(parent, @last_spawn, @last_child, response)
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
          max_depth: [@max_depth, ceiling].min, name: @name
        )
      end

      private

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

      def spawn_agent(parent, union, allowed)
        Agent.new(
          provider: @provider, context: @context_factory.call,
          toolset: @policy.posture.rendered_toolset(union:, allowed:),
          handler: child_handler(union, allowed),
          timeline: @policy.prefix.base_timeline(parent:, store: parent.store),
          session: Session::Null.instance, budget: @budget, journal: @journal
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
      def lineage
        @lineage ||= Lineage.new(policy: @policy)
      end

      def depth_exceeded
        Tool::Result.error("subagent spawn depth exceeded: this agent is at the spawn-depth ceiling")
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

# Both children reopen Subagent (and RefusingHandler subclasses Effect::Handler,
# long loaded by the time tools.rb requires this unit), so they load after the
# class body -- subagent.rb is this subtree's index, the effect/handler.rb
# convention.
require_relative "subagent/lineage"
require_relative "subagent/refusing_handler"
