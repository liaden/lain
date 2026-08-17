# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool # rubocop:disable Style/Documentation -- doc lives on the reopen below; see .rubocop.yml's note
      # The model-facing input: just the task. The prefix strategy, attenuation
      # posture, and `only`-set are the ARM (config), fixed at construction --
      # "what can this subagent do" stays one readable line, not a per-call
      # decision the model negotiates.
      class Input < Tool::Input
        field :prompt, :string, required: true,
                                description: "The task for the subagent to carry out on its own."
      end

      input_model Input

      # A spawn whose session posture permits none of its tools. Loud rather
      # than an empty child -- see {ChildBuilder#permitted}.
      class NoCapability < Error; end

      # The lifecycle axis (OM-2 vs OM-3), closed and loud: a mode outside this
      # set raises at construction rather than defaulting.
      MODES = %i[one_shot actor].freeze

      # The most recent spawn's records, exposed for observability: the study
      # bench reads the orchestration events, and a one-shot call is synchronous,
      # so the last :spawn/:message events and the child's final Timeline are the
      # honest projection of what the call did. `nil` until a spawn happens (and
      # after a depth refusal, which emits nothing).
      #
      # OM-2-ONLY statefulness (T19 panel #4): the seam's live parent handle and
      # these `@last_*` ivars are safe here because a Subagent instance belongs
      # to exactly one agent's toolset and a one-shot spawn runs synchronously
      # inside a single tool dispatch -- no interleaving writer can exist.
      # Returning the records along the call path instead is not cheap today:
      # {Tool::Result} content is pinned to String/Array wire blocks. The actor
      # mode (OM-3) does NOT inherit this shape -- concurrent children would
      # race these ivars, so an actor's record rides its events (its mailbox
      # projection and the journaled lifecycle), never tool state.
      attr_reader :name, :last_spawn, :last_message, :last_child

      # The {Seam} this tool spawns over, and the union a child attenuates FROM.
      # Both are read-side: the study bench asks "what could this child do, over
      # whose provider and journal", and it used to answer by reaching two deep
      # into {ChildBuilder}'s ivars, which pinned the extraction's private shape
      # rather than the capability layering the question is about.
      attr_reader :seam

      def attenuates_from = @builder.toolset

      # Two lifecycle modes over the same spawn machinery (OM-2/OM-3): `:one_shot`
      # runs a child to a single result within one dispatch (the 5-1 model);
      # `:actor` launches a long-lived {Actor} fiber whose outputs reach the
      # parent as mailbox events instead. `log` is the append-only read-side that
      # {Lineage} writes every event to -- the actor's mailbox folds it; the
      # one-shot defaults to {Log::Null} because nothing folds its stream.
      #
      # The spawn collaborators arrive as one `seam:` ({Seam}); the loose
      # keywords they used to be still work and land in `**spawn_over`, which
      # {Seam.resolve} turns into the same value. What is left here is this tool's
      # OWN axes -- the union, the policy, the budget, and the config triple
      # {#seed_config} closes over.
      # `announces_as` is what a HUMAN is told is asking when this spawn's
      # child puts a question to them (T10), and it defaults to `name` because
      # for most spawns they are the same word. They come apart on the one
      # child path that ships: the chat's `research_subagent` is NAMED
      # "subagent" because that is what the model calls, and IS a researcher,
      # which is what the arrival note and the desktop must say. A separate
      # keyword rather than a rename, because `name` is the model-facing tool
      # name and renaming it would change the rendered schema bytes.
      def initialize(toolset:, policy:, seam: nil, budget: Agent::Budget.new,
                     max_depth: 1, name: "subagent", announces_as: name, mode: :one_shot,
                     log: Log::Null, persona: Role::Persona::Null, **spawn_over)
        super()
        @seam = Seam.resolve(seam, **spawn_over)
        @announces_as = announces_as
        @builder = ChildBuilder.new(seam: @seam, toolset:, policy:, budget:, persona:, name: announces_as)
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

      # Run one prompt to a single final result, synchronously, WITHOUT the
      # model-facing {#call}/effect-handler dispatch or the actor launch: the
      # direct entry a role-selecting seam ({Skill::RoleSpawn}) drives when it
      # builds a one-shot Subagent per call and hands it a prompt. It rides the
      # same {#spawn_one_shot} machinery {#perform} uses -- so its records land
      # in @last_* identically -- and honors the depth ceiling the same way: at
      # the floor it returns the same is_error result, emitting no event and
      # touching no Store. One-shot only; the actor lifecycle needs the
      # Supervisor reactor {#perform} adopts onto, which a synchronous caller
      # here does not hold.
      def run(prompt)
        return depth_exceeded if @max_depth <= 0

        spawn_one_shot(prompt)
      end

      # Fan `prompts` out as sibling children, staggered (CE-5): sibling 1 is
      # dispatched alone and the rest release the instant its first token
      # arrives, so N cache-siblings pay one template WRITE and N-1 READs
      # instead of N cold prefills. Each dispatch unit is exactly the duck
      # {Stagger} gates on -- `#call(on_stream_started:)` -- and the observer it
      # threads is what {Agent#ask} forwards down the child's provider round
      # trip, so the stagger gate opens on the CHILD's real stream-start (not a
      # simulated one). The releases -- `:stream_started` or the `:degraded`
      # safety valve for a child that never streams -- land in this tool's
      # journal. Returns one {Tool::Result} per prompt, in `prompts`' order; an
      # empty fan-out spawns nothing.
      #
      # This is the programmatic sibling-template arm (bin/demo-fanout's live
      # equivalent), distinct from the model-dispatched {#perform}: the model
      # fanning several `subagent` calls out in one turn is the {Agent::ToolRunner}
      # gather path, ungated; this is the gated, orchestrator-driven fan-out.
      #
      # ECONOMIC PRECONDITION: staggering only pays under a `SiblingTemplate`
      # prefix policy, where the siblings share a byte-identical cache prefix so
      # sibling 1's write turns the rest into reads (CE-5). Under `:fresh` or
      # `:inherit` the siblings share no writable prefix, so gating on sibling
      # 1's first token buys nothing and merely serializes that first token's
      # latency ahead of the rest -- a pure loss. The caller owns the policy, so
      # this is a usage contract, not a guard here: fan a NON-template arm out
      # concurrently (the {Agent::ToolRunner} gather shape) rather than through
      # this method.
      #
      # Each dispatch unit is shaped after {Stagger}'s duck -- a lambda answering
      # `#call(on_stream_started:)` that spawns one child and forwards the
      # observer down its loop. The depth ceiling is honored per unit exactly as
      # {#run}/{#perform} honor it: a fan-out at the floor refuses each sibling
      # (and, firing no stream-start, releases the rest on the degrade path)
      # rather than escalating past the cap.
      #
      # @param prompts [Array<String>]
      # @return [Array<Tool::Result>]
      def fan_out(prompts)
        units = prompts.map do |prompt|
          ->(on_stream_started:) { @max_depth <= 0 ? depth_exceeded : spawn_one_shot(prompt, on_stream_started:) }
        end
        Stagger.new(journal:).call(units)
      end

      # Launch a long-lived {Actor} over a freshly built child, and return the
      # handle -- the orchestration seam a supervisor uses to `tell`/`stop` it
      # and read its Timeline. The fiber spawns on the current task, so the
      # caller must hold a reactor that outlives the parent's asks -- either an
      # orchestration Sync/Async above the Agent (programmatic use) or the
      # {Supervisor} task {#perform} adopts this launch onto.
      def launch_actor(prompt, parent: parent_timeline, worker_env: WorkerEnv.default)
        # Per launch, mirroring #perform: AC4's floor note has no lifecycle
        # exemption, so an actor-mode sibling under the floor is reported too.
        policy.prefix.journal_floor(journal)
        # The actor holds its child's asker registration because it holds the
        # child's LIFETIME: `Supervisor#stop` farewells every row through
        # `registration.actor.stop`, so a `deregister` there rides the same
        # lease teardown that reaps the fiber (T10). {ChildBuilder::Child}
        # owns what happens when no actor comes out of the launch at all.
        build_child(parent, worker_env).launched do |agent, registration|
          Actor.new(agent:, registration:, lineage:, parent:, journal:).launch(prompt)
        end
      end

      # A nested copy of this tool, for a child's union: the same {Seam} and the
      # same config ({ChildBuilder#config} re-injects both verbatim, rebinding
      # only the seam's parent handle to the CHILD, so the grandchild's lineage
      # names the child's head and not this parent's), with the ceiling capped at
      # `ceiling` -- never raised past this tool's own, so a tool wired to never
      # spawn (max_depth 0) stays that way whatever the spawner had left. Public
      # only for {ChildBuilder}, which builds the child's union -- it is not a
      # Subagent, so `protected` can no longer say "only the spawn machinery".
      def descend(parent:, ceiling:)
        config = @builder.config(parent:)
        self.class.new(**config, max_depth: [@max_depth, ceiling].min, name: @name,
                                 announces_as: @announces_as, mode: @mode, log: @log)
      end

      protected

      # A model-dispatched `:actor` is refused UNLESS a running {Supervisor} is
      # wired (T23 panel #1, unrefused by OM-6): Agent#ask's per-call Sync owns
      # any fiber a tool dispatch spawns, so a bare perform-launched actor
      # would park as ask's own child and structured concurrency would never
      # let ask return -- the loop wedges, outer reactor or not. The
      # Supervisor's reactor task is the fiber home that outlives the ask, so
      # {#adopt_actor} launches there; without one, the refusal (like the depth
      # cap) emits no event and touches no Store.
      def perform(input, _invocation)
        return depth_exceeded if @max_depth <= 0
        return adopt_actor(input.prompt) if @mode == :actor

        spawn_one_shot(input.prompt)
      end

      private

      # The adopted launch: the Supervisor runs {#launch_actor} under its own
      # reactor task, so the fiber persists past this dispatch, and the
      # tool_result carries the handle -- the actor's address (its :spawn
      # digest), the stable name a caller tells it by.
      def adopt_actor(prompt)
        return actor_refused unless supervisor.running?

        # The supervisor acquires this worker's isolation lease and hands its
        # WorkerEnv down, so the actor's child resolves cwd/env against it.
        actor = supervisor.adopt(role: @name) { |worker_env| launch_actor(prompt, worker_env:) }
        Tool::Result.ok("actor launched: #{actor.address}")
      end

      # The one-shot path is re-entrant by construction (5-1.4): the spawn's
      # records ride LOCALS, never the `@last_*` ivars, across `run_child`'s IO
      # yield -- so a sibling fan-out task resuming mid-flight cannot make
      # `message` name the wrong spawn or child. The ivars are written once at
      # the end, together (#remember), a single atomic burst with no yield
      # between the three, so the observability projection stays mutually
      # consistent under concurrency and exact under a one-shot call.
      def spawn_one_shot(prompt, on_stream_started: nil)
        # Per spawn, not per tool: the floor note (see PrefixStrategy::
        # SiblingTemplate#journal_floor) lands beside each :spawn it warns
        # about, so a fan-out's record shows which spawns ran un-cacheable.
        policy.prefix.journal_floor(journal)
        parent = parent_timeline
        spawn = lineage.spawn(parent)
        child, response = run_child(prompt, parent, on_stream_started:)
        message = lineage.message(parent, spawn, child, response)
        remember(spawn, child, message)
        Tool::Result.ok(response.text)
      end

      # The observability write, kept apart from #perform so the spawn path reads
      # as pure locals: this is the ONE place the `@last_*` ivars are set, all at
      # once with no yield between, so a reader never sees a half-updated record.
      def remember(spawn, child, message)
        @last_spawn = spawn
        @last_child = child
        @last_message = message
      end

      # `ask` seeds the prompt as the child's first user turn and drives its
      # loop to settle -- fresh starts that turn as a root, inherit starts it
      # on the parent's head (O(1) fork).
      def run_child(prompt, parent, on_stream_started: nil)
        build_child(parent, WorkerEnv.default).answered { |child| child.ask(prompt, on_stream_started:) }
      end

      def build_child(parent, worker_env) = @builder.build(parent, ceiling: @max_depth - 1, worker_env:)

      def policy = @builder.policy

      # The spawn's event record, delegated: {Lineage} writes the :spawn and
      # :message events (see that class for the causal-edge and correlation-
      # join reasoning). Memoized here, not built in #initialize, only to keep
      # the wiring point within its Metrics budget -- Lineage is pure over the
      # frozen policy, so late construction changes nothing.
      def lineage = @lineage ||= Lineage.new(policy:, log: @log, observer: lineage_observer)

      # An actor's lifecycle rides the journal (OM-6 AC): every event {Lineage}
      # writes -- the :spawn at launch, the settle reply, tells, the farewell --
      # is promoted to a {Telemetry::Message}, the same flat record the session
      # scribe writes, whose kind/digest/to/causal_parents shape is exactly
      # what {StatusFeed}'s fleet field consumes. One-shot mode keeps the plain
      # observer: its records already ride the tool_result and the scribe, and
      # its journal contents are pinned by existing specs.
      def lineage_observer = @mode == :actor ? method(:journal_lifecycle) : observer

      def journal_lifecycle(event)
        journal << Telemetry::Message.from_event(event)
        observer.call(event)
      end

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
        handle = @seam.parent
        handle.respond_to?(:call) ? handle.call : handle
      end

      # The seam's members, read by name: the spawn path says `journal` and
      # `observer`, which is what the six were called when they were keywords.
      def journal = @seam.journal
      def observer = @seam.observer
      def supervisor = @seam.supervisor
    end

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
    # time, as one {Seam} value -- provider, a child-Context factory, the live
    # parent handle, a journal, the {Supervisor} a model-dispatched actor
    # launches under, the lineage observer, the session posture's gate policy
    # and permitted capabilities, and the run's ask-the-human seam (a child is
    # enrolled on it and holds an asker of its OWN, never the parent's -- see
    # {ChildBuilder#build}) -- plus this tool's OWN axes: the
    # union toolset it attenuates from, the spawn {Tool::SpawnPolicy}, a Budget,
    # and a spawn-depth ceiling. The dispatch duck stays the Session (the
    # `context:` a tool receives), which this tool does not read: everything it
    # needs to spawn was injected, so the ToolRunner and the Session interface
    # are untouched. `Seam#parent` is a live handle to the parent Timeline (a
    # Timeline or a `-> Timeline` thunk, since the toolset is built before the
    # Agent) -- the one collaborator the render chain cannot supply, because H is
    # the parent's head at the instant of the call. The shared Store rides ON
    # that handle (`parent.store`): H, F, and both events live in one
    # content-addressed forest, so deriving it from the parent is one source of
    # truth rather than a separately-injected reference that could silently
    # desync. The spawn wiring itself -- what a child IS -- lives in
    # {ChildBuilder}; this class decides WHEN one may spawn (depth, mode,
    # supervisor presence).
    #
    # == The depth ceiling
    #
    # Recursion (a child holding a subagent tool) has no natural floor, so
    # `max_depth` is a hard ceiling: at 0 the tool refuses to spawn (an is_error
    # result), emitting no event and touching no Store. The ceiling is
    # TRANSITIVE by construction: when a child's union is built, every Subagent
    # reachable in it is REPLACED by a copy whose ceiling is
    # `min(its own, this one - 1)` (see {ChildBuilder}) -- decrementing so the
    # chain terminates, `min` so a descendant's own tighter ceiling is never
    # RAISED by the copy (that would be capability escalation). No Budget
    # change: the ceiling is a property of the tool, not of the loop.
    class Subagent < Tool
      # Reopened rather than nested mid-body -- the shutdown.rb idiom: the spawn
      # wiring and the value it is wired FROM are each their own responsibility
      # (the extraction the Metrics trip named), and the split keeps each class
      # body within Metrics/ClassLength instead of loosening it.

      # The {Seam} observer default, as ONE frozen object. Its two neighbours are
      # already singletons (`Channel::Null.instance`, `Supervisor::Null`), so
      # defaulting this one to a fresh `ChainWriter::Null.new` made
      # `Seam.new(**three) == Seam.new(**three)` FALSE -- a value whose equality
      # depends on WHICH member the caller let default is a trap, and Data's
      # member-wise `==` is only ever as deep as its members ({Skill::Library}
      # files the same caveat). Sharing one is safe because it holds no state:
      # `#call` swallows the event and returns self. Frozen says so mechanically,
      # and is what makes an all-defaults Seam's shareability turn only on the
      # three collaborators that are genuinely live.
      #
      # It lives on {Subagent}, not inside the `Data.define` block: a constant
      # written in that block lands in the ENCLOSING module rather than on the
      # Data class (the `Request::SYSTEM_PREFIX` trap), and the block's own
      # constant lookup is lexical from here anyway.
      NO_OBSERVER = Event::ChainWriter::Null.new.freeze

      # The gate a child runs behind when nothing wired one: approve every tier-3
      # call, which is byte-for-byte the behaviour children had before they were
      # gated at all. It is a shared frozen instance for {NO_OBSERVER}'s exact
      # reason -- a fresh `ApproveAll.new` per default would make two otherwise
      # identical Seams compare unequal -- and it is safe to share because the
      # policy holds no state.
      #
      # Approving rather than denying is the deliberate direction, against
      # {Effect::Handler::Gate}'s own fail-closed default: a child spawned by a
      # harness that never wired a queue has no surface to answer it, and the
      # roles the harness spawns UNATTENDED would then park or refuse forever
      # (`role/catalog.rb`'s note on `:merge_resolver`). A caller that wants the
      # session's gate passes it; absence means "this seam was never taught about
      # a gate", not "deny".
      UNGATED = Effect::Handler::Gate::ApproveAll.new.freeze

      # The path axis a seam was never taught about, and {UNGATED}'s opposite
      # direction on purpose: absence here means "nobody told this seam which
      # paths are sensitive", so nothing is, which is byte-for-byte what a child
      # did before the path boundary existed. A shared instance for the same
      # reason -- two Seams that wired nothing must still compare equal.
      #
      # `lain.rb` loads `lain/sensitivity` forty entries BEFORE `lain/tools`, so
      # unlike `mode/resolution.rb`'s deferred lookups this one may resolve
      # eagerly in the class body.
      UNJUDGED = Sensitivity::Policy::Null.instance

      # The ask-the-human seam a spawn was never taught about -- {Seam}'s
      # `askers` default, answering the one message a spawn sends it.
      #
      # It enrols a bare {AskHuman}: a child built over it HOLDS the capability
      # and writes its Q into the shared Store, but announcement lives in
      # {AskHuman::Notifying}, so the question reaches no queue and no desktop,
      # and {AskHuman::Directory::Unheld} is the registration, so no answer can
      # be routed to it either. That is deliberately the same wired-to-nothing
      # state {CLI::Wiring::Askers.unwired} is, said in the layer that may not
      # name it: `lain.rb` loads `lain/cli` before `lain/tools`, so this file
      # cannot reference that class, and neither should it -- a spawn asks for
      # an enrolment, not for the CLI's way of making one.
      #
      # It is NOT a sanctioned production state: a child parked on a question
      # nobody can see is the exact failure the arrival seam exists to prevent,
      # and the exe passes the run's own {CLI::Wiring::Askers}.
      #
      # A module rather than an instance, for {NO_OBSERVER}'s reason: a fresh
      # object per default would make two otherwise identical Seams compare
      # unequal. It holds no state, so sharing one is free.
      module NoAskers
        # The same two halves {CLI::Wiring::Askers::Enrolled} carries, because
        # this answers the same duck: the child's own asker, and the thing
        # whoever owns that child's lifetime `deregister`s.
        Enrolled = Data.define(:asker, :registration)

        # `**` and not `agent:`, because there is nobody to name an asker TO.
        def self.enrol(parent, **)
          Enrolled.new(asker: AskHuman.new(parent:), registration: AskHuman::Directory::Unheld)
        end

        def self.inspect = "Lain::Tools::Subagent::NoAskers"
        def self.to_s = inspect
      end

      # What a child spawn is built OVER: the collaborators every spawn needs
      # and no single spawn chooses -- the run's provider, a child-Context
      # factory, the live parent handle, the journal, the {Supervisor} a
      # model-dispatched actor adopts onto, the lineage observer, and the two
      # axes the SESSION's posture governs (T11): the approval policy a tier-3
      # call must pass, and which capabilities a child may hold at all -- plus
      # the run's ask-the-human seam (T10), which is where a child gets an
      # asker OF ITS OWN rather than inheriting the parent's, and the session's
      # sensitivity policy, which is the PATH half of the same gate.
      #
      # They were six loose keywords on three signatures ({Subagent},
      # {ChildBuilder}, {Skill::RoleSpawn}) plus one Hash literal in
      # {CLI::Wiring::ToolsetBuild}, whose own class comment says the tell out
      # loud: "a triple passed identically at every call is state an object is
      # missing, not arguments". This is that object, so a seventh collaborator
      # is one member and one wiring line rather than four edits that can be
      # three-quarters done.
      #
      # It nests HERE, under the class all three adopters build, because that is
      # what they have in common: {Skill::RoleSpawn} exists to construct a
      # {Subagent} per call, {ToolsetBuild} to wire one. A top-level
      # `Lain::Spawn::Seam` would sit a hand's breadth from {Bench::SpawnSeam},
      # a DIFFERENT duck (`call(journal:, **spawn_opts) -> Agent`) -- the
      # same-name-different-thing problem the simplification review itself filed
      # against the four Gates.
      #
      # `toolset` is deliberately NOT a member: each adopter attenuates over a
      # different base union (see {ToolsetBuild}'s layering), so it is per-caller
      # state, not shared seam state.
      #
      # Frozen, like every Data, but NOT `Ractor.shareable?` and not aspiring to
      # be -- `context_factory` is always a callable, a provider is always a live
      # client, and `parent` is a thunk or a Timeline (measured: neither is
      # shareable). The journal is NOT among the reasons: its default here is
      # `Channel::Null.instance`, which IS shareable. Neither is `askers`, whose
      # default is a module: T10 added a ninth member and moved that claim in
      # NEITHER direction, which is the thing a new member has to say out loud.
      # The tenth, `sensitivity`, moves it in NEITHER direction either: its
      # default is a frozen {Sensitivity::Policy::Null} instance, which IS
      # shareable, and the live one holds a frozen classifier.
      # This bundles collaborators; it is not a value in the {Event}/{Canonical}
      # sense.
      Seam = Data.define(:provider, :context_factory, :parent, :journal, :supervisor, :observer,
                         :gate_policy, :permits, :askers, :sensitivity) do
        # Everything after `parent` defaults to its Null object, so a caller who
        # wires none of them gets byte-identically what the pre-seam constructors'
        # own defaults gave -- {UNGATED} and {Mode::Posture::Permits::All} are the
        # two that say "no posture has been bound to this seam". The first three
        # have no Null and stay required: Data's own missing-keyword error is the
        # loud failure, unwritten.
        def initialize(provider:, context_factory:, parent:, journal: Channel::Null.instance,
                       supervisor: Supervisor::Null, observer: NO_OBSERVER,
                       gate_policy: UNGATED, permits: Mode::Posture::Permits::All, askers: NoAskers,
                       sensitivity: UNJUDGED)
          super
        end

        # Adoption is additive, in ONE place: a caller passes `seam:` or the loose
        # members, and the adopting constructor's `**` splat lands here. Both at
        # once cannot be honored, so it raises rather than silently preferring one
        # and dropping the other.
        #
        # A stray keyword is a TYPO, not a conflict, and the two must not be
        # confused: on the loose path Data's own `new` says `unknown keyword:
        # :max_dept`, and reporting the same key as "you passed a seam AND its
        # members" would send the reader hunting for a member they never passed.
        # So the seam path partitions first and says the same thing Ruby does.
        def self.resolve(seam, **members)
          return new(**members) if seam.nil?

          refuse_unknown(members.keys - self.members)
          raise ArgumentError, "pass seam: or its members #{members.keys.inspect}, not both" unless members.empty?

          seam
        end

        def self.refuse_unknown(unknown)
          return if unknown.empty?

          raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")}"
        end
        private_class_method :refuse_unknown
      end

      # What a child IS, given the injected collaborators: the union it renders,
      # the Agent over it, the handler enforcing the posture. {Subagent} decides
      # WHEN one may spawn (depth, mode, supervisor presence); this builds it.
      # Parent-agnostic by construction -- `parent` arrives per {#build}, never
      # at initialize -- so one builder serves every spawn and every descended
      # copy ({#config}) without carrying spawn-specific state.
      class ChildBuilder
        # A built child and the enrolment that came with it. Two halves because
        # a child now has TWO lifetimes to answer for: the Agent, which the
        # caller runs, and the {AskHuman::Directory::Registration}, which
        # nothing but a `deregister` releases -- so whoever owns the child owns
        # both, and neither may be discovered later by reaching into the other.
        #
        # Holding the pair is also what lets it own the release, and there are
        # exactly two lifetimes to release against -- which is why both live
        # here rather than as two shapes of the same `ensure` copied into
        # {Subagent}. Both are `ensure`, never `rescue StandardError`: a
        # cancelled dispatch raises `Async::Stop`, which is not a
        # StandardError, and a child cancelled mid-ask is as unreachable as
        # one that returned.
        Child = Data.define(:agent, :registration) do
          # A one-shot child's lifetime IS the dispatch, so the release lands
          # on every exit from it -- answered, refused, raised or unwound.
          # `timeline` is read AFTER the block, because the caller wants the
          # child's settled head and not the one it started from.
          def answered
            response = yield(agent)
            [agent.timeline, response]
          ensure
            registration.deregister
          end

          # An actor's lifetime outlives the launch, so the registration goes
          # WITH it -- unless no actor comes out of the launch at all, in
          # which case the release happens here or never: the Actor reference
          # goes with the raise, so nothing else could ever hold this. That is
          # the whole reason enrolment happens inside the launch.
          def launched
            actor = nil
            actor = yield(agent, registration)
          ensure
            registration.deregister unless actor
          end
        end

        attr_reader :policy, :toolset

        # `name` is what a human is TOLD is asking when this child puts a
        # question to them ({CLI::Wiring::Askers#enrol}'s `agent:`) -- the
        # spawn's own name, so a role spawn announces as "researcher" rather
        # than as a 71-character correlation.
        def initialize(seam:, toolset:, policy:, budget:, persona: Role::Persona::Null, name: "subagent")
          @seam = seam
          @toolset = toolset
          @policy = policy
          @budget = budget
          @persona = persona
          @name = name
        end

        # The constructor kwargs a descended copy re-injects ({Subagent#descend}):
        # spawn wiring is shared config, so every copy gets it verbatim -- the
        # persona included, so a grandchild renders the same role framing, and the
        # seam's observer and supervisor along with it (a grandchild's events must
        # reach the same scribe, or nested spawns silently vanish from the session
        # record, and its actors the same reactor).
        #
        # `parent` is the ONE member a copy does not inherit: it points at the
        # CHILD, so the grandchild's lineage names the child's live head.
        def config(parent:)
          { seam: @seam.with(parent:), toolset: @toolset, policy: @policy,
            budget: @budget, persona: @persona }
        end

        # A fresh child Agent over the base Timeline the prefix strategy chose,
        # rendering the toolset the posture chose, enforced by the handler the
        # posture chose -- and the asker enrolled for it (T10). `child` is
        # late-bound through the thunk EXACTLY as the exe wires the tool
        # itself: the union must exist before the Agent, but a grandchild's
        # lineage must name the child's LIVE head at its own spawn instant, and
        # the child's asker must attribute its questions to the child's own
        # chain rather than to the parent's.
        #
        # The handle is therefore the ONE thing the asker and the union share,
        # and it is why enrolment happens here rather than at the tool: nothing
        # above this method can name a child that does not exist yet.
        def build(parent, ceiling:, worker_env: WorkerEnv.default)
          child = nil
          handle = -> { child.timeline }
          union = child_union(handle, ceiling)
          spawned(@seam.askers.enrol(handle, agent: @name), parent, union, worker_env)
            .tap { |built| child = built.agent }
        end

        private

        # The enrolment, released if the child never comes into being. A spawn
        # that raises past this point ({NoCapability}, a Context that will not
        # render) leaves no lifetime for anyone to hang a `deregister` on, and
        # retention runs from `register` to `deregister` and nothing else --
        # so this method is the only place that release can live.
        def spawned(enrolled, parent, union, worker_env)
          child = nil
          asker = enrolled.asker
          allowed = granted(permitted(@policy.attenuate(union)), asker)
          child = Child.new(agent: spawn_agent(parent, granted(union, asker), allowed, worker_env),
                            registration: enrolled.registration)
        ensure
          # Keyed on the handle rather than written as `rescue StandardError`,
          # so a CANCELLED spawn releases too -- `Async::Stop` is not a
          # StandardError, and a child cancelled mid-build is as unreachable
          # as one that raised.
          enrolled.registration.deregister unless child
        end

        # The child's own asker, granted ON TOP of the attenuated set rather
        # than folded into the union it attenuates from: no role in the catalog
        # names `ask_human` in its `only`-set (`role/catalog.rb`), so a set that
        # went through {Tool::SpawnPolicy#attenuate} would have dropped it.
        # {#permitted} runs BEFORE this for the same reason it always did --
        # "the posture permits none of the SPAWN's tools" is a wiring error
        # whether or not the child could still ask a human about it.
        #
        # The session posture still governs the grant, which is the half a
        # future reader must not lose: a rung that stopped permitting
        # `ask_human` would MUTE every child rather than being quietly granted
        # past. It is in `plan`'s READ_ONLY today, deliberately and with the
        # reasoning beside it; specs pin both directions.
        #
        # REPLACING rather than appending, and that is the important half: a
        # union that already holds an `ask_human` holds the PARENT's, whose
        # questions would be attributed to the parent's chain and whose promise
        # the parent's {AskHuman::Outstanding} holds. (Appending would also
        # raise {Toolset::DuplicateTool}, which is the same fact said louder.)
        # The strip is UNCONDITIONAL and the grant is not, which is the whole
        # of the muted case: a posture that does not permit `ask_human` must
        # leave the child holding none at all, and an early return here would
        # leave the PARENT's standing in the dispatch union -- reachable by
        # the very child the posture just muted (under `handler_union` it is
        # also rendered), resolving into the parent's own {Outstanding}.
        def granted(set, asker)
          own = @seam.permits.include?(asker.name) ? [asker] : []
          Toolset.new(set.reject { |tool| tool.name == asker.name } + own)
        end

        # The child's capability set: the spawn policy's own attenuation, and
        # then the SESSION posture's -- a `plan`-mode parent must not be able to
        # hand a child the `bash` it does not itself hold, which four shipped
        # roles would otherwise take (`role/catalog.rb:22-27`).
        #
        # An INTERSECTION, deliberately, rather than {Mode::Posture#attenuate}:
        # that goes through {Toolset#only}, which raises on a name the set does
        # not hold, so asking `plan` to attenuate a `:merge_resolver` child's
        # four tools would die on the nine read-only names the child never held.
        # A spawn under a restrictive posture must ANSWER "here is what you may
        # hold", not blow up. `Permits#include?` is the other half of that duck
        # for exactly this: it asks one name at a time, so no arm of the ladder
        # needs the child's set to be a superset of its own.
        #
        # == This is read PER SPAWN, and `gate_policy` is read per CALL
        #
        # The two axes a posture governs do not have the same liveness, and the
        # difference is observable. A child renders a plain frozen {Toolset}
        # once, here; the gate answers through a live policy on every call. So a
        # `:one_shot` child, which begins and ends inside one dispatch, cannot
        # straddle a flip -- but an `:actor` adopted onto the {Supervisor} can,
        # and it keeps the set it was rendered. Under `/mode plan` the parent
        # loses `edit_file` that same turn while an in-flight actor does not,
        # and `plan`'s `DenyAll` intercepts only TIER 3, so that actor's
        # `edit_file` still runs. "Plan mutates nothing" is therefore a claim
        # about the session and about every child spawned AFTER the flip -- not
        # about a child already running. Making it true for those too means a
        # live toolset slot in the child ({CLI::Switchboard::LiveToolset} is the
        # shape), which is a design change this card did not make.
        def permitted(allowed)
          permitted = allowed.only(*allowed.names.select { |name| @seam.permits.include?(name) })
          raise NoCapability, no_capability(allowed) if permitted.empty?

          permitted
        end

        # A child with nothing at all is a wiring error, not a tighter child:
        # it renders an empty tools block, can do nothing about its prompt, and
        # will burn a round trip discovering that. Unreachable from the shipped
        # catalog -- every built-in role holds `read_file`, which every posture
        # permits -- so this names both halves, because the reader hit it by
        # pairing a custom `only:` with a posture that shares no name with it
        # and needs to know which of the two to change.
        def no_capability(allowed)
          "a #{@seam.permits} session permits none of the spawn's tools " \
            "(#{allowed.names.join(", ")}), so the child would hold nothing"
        end

        # The child's union: the injected one, with every Subagent in it
        # replaced by a descended copy -- the transitive-ceiling fix (T19
        # panel). Handing the SAME instances down would let a nested spawn keep
        # its constructing ceiling, and recursion would never terminate via the
        # cap. The copy's schema bytes are identical (same name/description/
        # input), so the rendered tools block -- and with it the cache prefix
        # -- is unchanged.
        def child_union(parent_handle, ceiling)
          Toolset.new(@toolset.map do |tool|
            tool.is_a?(Subagent) ? tool.descend(parent: parent_handle, ceiling:) : tool
          end)
        end

        # A fresh {Session} per spawn -- never {Session::Null} -- so a
        # write-capable child (read_file + edit_file in its `only`-set) can
        # satisfy EditFile's read-before-write contract against its OWN
        # read-set. Built here, not memoized: a builder is reused across
        # sibling spawns (T19's re-entrancy contract), so a memoized Session
        # would leak one sibling's reads into the next. `Session.new` never
        # sees the parent's Session -- this builder was never handed a
        # reference to it -- so the child's read-set starts empty by
        # construction. The prefix strategy shapes the factory's product
        # (`sibling_template` appends its shared template as the
        # marked-by-Context system tail; the other arms pass it through), so
        # template threading rides the SAME injected-factory seam the exe
        # already wires. The journal rides along so a strategy that rewrites
        # the factory's system (a stripped caller mark) can say so in the
        # record.
        def spawn_agent(parent, union, allowed, worker_env)
          agent = nil
          base = @policy.prefix.base_timeline(parent:, store: parent.store)
          agent = Agent.new(
            provider: @seam.provider, context: child_context,
            toolset: @policy.posture.rendered_toolset(union:, allowed:), handler: child_handler(union, allowed),
            timeline: base, turn_middleware: recorded_turns(base.head_digest) { agent.timeline },
            session: Session.new(worker_env:), budget: @budget, journal: @seam.journal
          )
        end

        # The child's turns, into the session record. Per ITERATION, through the
        # same {Middleware::JournalTurns} a chat wraps its own loop in, and that
        # granularity is the point: a child's `ask_human` question is written
        # DURING an iteration and cites the head that iteration committed, so a
        # feed that waited for the child to settle would record the turn after
        # the question that names it. `agent.timeline` is read through a thunk
        # for {Middleware::JournalTurns}' own reason -- the turn env carries the
        # PRE-step snapshot -- and late-bound because the middleware must exist
        # before the Agent that runs it, the same shape {#build} uses.
        def recorded_turns(base, &timeline)
          Middleware::Stack.new(
            [Middleware::JournalTurns.new(scribe: TurnFeed.new(observer: @seam.observer, base:), timeline:)]
          )
        end

        # The child's Context, in two composed reshapes over the factory's: the
        # PERSONA first (its system becomes the role prelude segments -- a Null
        # persona is identity, so a role-less spawn is untouched), then the
        # PREFIX strategy (sibling_template's shared tail, identity on the other
        # arms). Persona is the inner reshape so the role's marked bulk is what a
        # fresh child renders; a strategy that rewrites system sees the persona'd
        # context, not the bare factory one.
        def child_context
          @policy.prefix.child_context(@persona.child_context(@seam.context_factory.call), journal: @seam.journal)
        end

        # `schema` renders the attenuated set, so a plain executor over it
        # suffices; `handler_union` renders the shared union, so the
        # RefusingHandler enforces the `only`-set the model can now see but
        # must not use. Both dispatch against the DESCENDED union, never the
        # injected toolset, so a permitted nested subagent runs at its
        # decremented ceiling. Both run behind {#gated}.
        #
        # Under `handler_union` a `plan`-mode child is SHOWN the tools the
        # posture forbids it and refused at dispatch, which reads against
        # {Mode::Posture}'s own note that plan is safe because "the rendered
        # schema simply does not contain `edit_file`". The capability reading is
        # the correct one, and that note describes the DEFAULT posture's
        # mechanism rather than the guarantee: what plan promises is that the
        # child cannot dispatch a mutating tool, and {Toolset}'s attenuation
        # comment already names both halves of the model-facing surface -- the
        # rendered schema AND the `include?`/`fetch` pair {Effect::Handler::Live}
        # authorizes against. `schema` withholds the name; `handler_union` shows
        # it and refuses it. Neither can dispatch it, which is the promise.
        def child_handler(union, allowed)
          return gated(Effect::Handler::Live.new(toolset: allowed)) unless @policy.posture.refuses_over_union?

          RefusingHandler.new(allowed: allowed.names, journal: @seam.journal,
                              inner: gated(Effect::Handler::Live.new(toolset: union)))
        end

        # The session's approval gate, in front of the child's executor: a child
        # holding a tier-3 tool asks the SAME policy its parent asks, so `bash`
        # is not ungated merely because a subagent is the one calling it (T11).
        # A denial arrives as an is_error {Tool::Result}, never a raise -- that
        # is {Effect::Handler::Gate}'s own contract, and it is what keeps the
        # child's loop running rather than wedging on a refusal.
        #
        # It is composed INSIDE the RefusingHandler above, not around it, and
        # the order is the whole point: a call the child was never attenuated to
        # must be refused outright, not parked for a human who would then watch
        # it be refused anyway. Under `schema` there is no refusal layer to sit
        # behind -- a name outside the rendered set resolves to no tool, so the
        # gate declines it and {Effect::Handler::Live} reports the unknown tool.
        # The seam carries BOTH gating axes, and the second one is not optional:
        # a child gate built without the session's sensitivity policy would let
        # a subagent read a path its parent must ask about -- a privilege
        # inversion, since the child is the LESS supervised of the two. It is
        # read per call through the same board thunk `gate_policy` travels, so
        # the two can never resolve to different sessions.
        # Ahead of that gate sits the DENIAL half (T12), over the same seam and
        # the same board thunk, and it is here rather than only in
        # {CLI::Switchboard#gate} for the reason the sensitivity axis itself is:
        # a child gated only by its parent's chain reads what its parent may
        # not, and the child is the LESS supervised of the two. No new Seam
        # member -- `sensitivity` and `journal` are both already on it, and
        # {UNJUDGED} denies nothing, so a spawn that wired neither is unchanged.
        def gated(inner)
          Effect::Handler::Sensitivity.new(
            sensitivity: @seam.sensitivity, journal: @seam.journal,
            inner: Effect::Handler::Gate.new(policy: @seam.gate_policy, sensitivity: @seam.sensitivity, inner:)
          )
        end
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
require_relative "subagent/turn_feed"
require_relative "subagent/refusing_handler"
require_relative "subagent/actor"
require_relative "subagent/stagger"
