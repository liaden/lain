# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "monitor"

module Lain
  module Tools
    class Subagent < Tool # rubocop:disable Style/Documentation -- doc lives on the reopen below; see .rubocop.yml's note
      # Just the task. Prefix strategy, attenuation posture and `only`-set are
      # construction-time config, so what a subagent may do is never a per-call
      # decision the model negotiates.
      class Input < Tool::Input
        field :prompt, :string, required: true,
                                description: "The task for the subagent to carry out on its own."
      end

      input_model Input

      # A spawn whose session posture permits none of its tools. Loud rather
      # than an empty child -- see {ChildBuilder#permitted}.
      class NoCapability < Error; end

      # Closed and loud: a mode outside this set raises at construction.
      MODES = %i[one_shot actor].freeze

      # The most recent spawn's records, for observability. `nil` until a spawn
      # happens, and after a depth refusal, which emits nothing.
      #
      # ONE-SHOT ONLY. These ivars are safe only because a Subagent belongs to
      # exactly one agent's toolset and a one-shot spawn runs synchronously
      # inside a single tool dispatch, so no interleaving writer can exist.
      # Returning the records along the call path instead is not available:
      # {Tool::Result} content is pinned to String/Array wire blocks. Actor mode
      # must NOT inherit this shape -- concurrent children would race these
      # ivars, so an actor's record rides its events instead.
      attr_reader :name, :last_spawn, :last_message, :last_child

      # The {Seam} this tool spawns over, and the union a child attenuates FROM.
      # Exposed so the bench asks the capability layering directly rather than
      # reaching two deep into {ChildBuilder}'s private ivars for it.
      attr_reader :seam

      def attenuates_from = @builder.toolset

      # `:one_shot` runs a child to a single result within one dispatch;
      # `:actor` launches a long-lived {Actor} fiber whose outputs reach the
      # parent as mailbox events instead. `log` is the append-only read-side
      # {Lineage} writes every event to -- the actor's mailbox folds it, and
      # one-shot defaults to {Log::Null} because nothing folds its stream.
      # Spawn collaborators arrive as one `seam:`; the loose keywords they used
      # to be land in `**spawn_over`, which {Seam.resolve} makes the same value of.
      #
      # `announces_as` is what a HUMAN is told is asking when this spawn's child
      # puts a question to them, and defaults to `name` because for most spawns
      # they are the same word. A separate keyword rather than a rename: `name`
      # is the model-facing tool name, so renaming it would change the rendered
      # schema bytes.
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

      # Each child runs a SEPARATE Timeline over the SHARED, Monitor-guarded,
      # content-addressed Store, so parallel commits neither race nor reorder
      # gate 2 (which orders the parent's returned blocks, not Store insertion).
      # The spawn path itself is re-entrant: see {#spawn_one_shot}, which threads
      # records through LOCALS across the child's IO yield point.
      def parallel_safe? = true

      # Run one prompt to a single final result, synchronously, WITHOUT the
      # model-facing dispatch -- the direct entry {Skill::RoleSpawn} drives.
      # Rides the same {#spawn_one_shot} machinery {#perform} does, so records
      # land in @last_* identically and the floor returns the same is_error
      # result, emitting no event and touching no Store. One-shot only: the
      # actor lifecycle needs the Supervisor reactor {#perform} adopts onto,
      # which a synchronous caller here does not hold.
      def run(prompt)
        return depth_exceeded if @max_depth <= 0

        spawn_one_shot(prompt)
      end

      # Fan `prompts` out as sibling children, staggered: sibling 1 is
      # dispatched alone and the rest release the instant its first token
      # arrives, so N cache-siblings pay one template WRITE and N-1 READs
      # instead of N cold prefills. The observer each unit threads is what
      # {Agent#ask} forwards down the child's provider round trip, so the gate
      # opens on the CHILD's real stream-start, not a simulated one; the
      # releases -- `:stream_started`, or the `:degraded` valve for a child that
      # never streams -- land in this tool's journal.
      #
      # ECONOMIC PRECONDITION: staggering only pays under a `SiblingTemplate`
      # prefix policy, where the siblings share a byte-identical cache prefix so
      # sibling 1's write turns the rest into reads. Under `:fresh` or
      # `:inherit` the siblings share no writable prefix, so gating on sibling
      # 1's first token buys nothing and merely serializes that first token's
      # latency ahead of the rest -- a pure loss. The caller owns the policy, so
      # this is a usage contract, not a guard here: fan a NON-template arm out
      # through the {Agent::ToolRunner} gather path instead. That gather path is
      # also what the model takes when it fans several `subagent` calls out in
      # one turn; this method is the gated, orchestrator-driven arm.
      #
      # The depth ceiling is honored per unit: a fan-out at the floor refuses
      # each sibling and, firing no stream-start, releases the rest on degrade.
      #
      # @param prompts [Array<String>]
      # @return [Array<Tool::Result>]
      def fan_out(prompts)
        units = prompts.map do |prompt|
          ->(on_stream_started:) { @max_depth <= 0 ? depth_exceeded : spawn_one_shot(prompt, on_stream_started:) }
        end
        Stagger.new(journal:).call(units)
      end

      # Launch a long-lived {Actor} over a freshly built child, and return its
      # handle. The fiber spawns on the CURRENT task, so the caller must hold a
      # reactor that outlives the parent's asks -- an orchestration Sync/Async
      # above the Agent, or the {Supervisor} task {#perform} adopts onto.
      def launch_actor(prompt, parent: parent_timeline, worker_env: WorkerEnv.default)
        # Per launch: the floor note has no lifecycle exemption, so an
        # actor-mode sibling under the floor is reported too.
        policy.prefix.journal_floor(journal)
        # The actor holds its child's asker registration because it holds the
        # child's LIFETIME: `Supervisor#stop` farewells every row, so a
        # `deregister` there rides the same lease teardown that reaps the fiber.
        # {ChildBuilder::Child} owns the case where no actor comes out at all.
        build_child(parent, worker_env).launched do |agent, registration|
          Actor.new(agent:, registration:, lineage:, parent:, journal:).launch(prompt)
        end
      end

      # A nested copy of this tool, for a child's union: same {Seam} and config,
      # rebinding the seam's parent handle to the CHILD so the grandchild's
      # lineage names the child's head, and its escalation road to the CHILD's
      # OWN ({ChildBuilder#config}) so a grandchild's question relays through
      # the child rather than skipping it. The ceiling is capped, never RAISED
      # past this tool's own, so a tool wired never to spawn (max_depth 0)
      # stays that way whatever the spawner had left. Public only for
      # {ChildBuilder}, which is not a Subagent, so `protected` can no longer
      # say "only the spawn machinery".
      def descend(parent:, escalation:, ceiling:)
        config = @builder.config(parent:, escalation:)
        self.class.new(**config, max_depth: [@max_depth, ceiling].min, name: @name,
                                 announces_as: @announces_as, mode: @mode, log: @log)
      end

      protected

      # A model-dispatched `:actor` is refused UNLESS a running {Supervisor} is
      # wired: Agent#ask's per-call Sync owns any fiber a tool dispatch spawns,
      # so a bare perform-launched actor would park as ask's own child and
      # structured concurrency would never let ask return -- the loop wedges,
      # outer reactor or not. The Supervisor's reactor task is the fiber home
      # that outlives the ask. Like the depth cap, the refusal emits no event
      # and touches no Store.
      def perform(input, _invocation)
        return depth_exceeded if @max_depth <= 0
        return adopt_actor(input.prompt) if @mode == :actor

        spawn_one_shot(input.prompt)
      end

      private

      # The Supervisor runs {#launch_actor} under its own reactor task, so the
      # fiber persists past this dispatch. The result carries the actor's
      # address -- its :spawn digest, the stable name a caller tells it by.
      def adopt_actor(prompt)
        return actor_refused unless supervisor.running?

        # The supervisor acquires this worker's isolation lease and hands its
        # WorkerEnv down, so the actor's child resolves cwd/env against it.
        actor = supervisor.adopt(role: @name) { |worker_env| launch_actor(prompt, worker_env:) }
        Tool::Result.ok("actor launched: #{actor.address}")
      end

      # Re-entrant by construction: the records ride LOCALS, never the `@last_*`
      # ivars, across `run_child`'s IO yield -- so a sibling fan-out task
      # resuming mid-flight cannot make `message` name the wrong spawn or child.
      # The ivars are written once at the end, together, with no yield between
      # the three.
      def spawn_one_shot(prompt, on_stream_started: nil)
        # Per spawn, not per tool, so a fan-out's record shows WHICH spawns
        # ran un-cacheable.
        policy.prefix.journal_floor(journal)
        parent = parent_timeline
        spawn = lineage.spawn(parent)
        child, response = run_child(prompt, parent, on_stream_started:)
        message = lineage.message(parent, spawn, child, response)
        remember(spawn, child, message)
        Tool::Result.ok(response.text)
      end

      # The ONE place the `@last_*` ivars are set, all at once with no yield
      # between, so a reader never sees a half-updated record.
      def remember(spawn, child, message)
        @last_spawn = spawn
        @last_child = child
        @last_message = message
      end

      # `ask` seeds the prompt as the child's first user turn: fresh starts it
      # as a root, inherit starts it on the parent's head (an O(1) fork).
      #
      # Every one-shot dispatch runs in a leased environment, and the lease is
      # taken UNCONDITIONALLY: {Isolation::Null} hands back {WorkerEnv.default}
      # and reclaims nothing, so an unisolated run is the run it always was and
      # there is no `if isolation` here to get the sense of backwards. The
      # ACTOR path does not come through here -- {Supervisor#adopt} acquires
      # that lease and hands its env to {#launch_actor}, and leasing twice for
      # one worker would be two checkouts where the operator asked for one.
      #
      # The journal is the SEAM's, read through the same delegator every other
      # record on this path uses, so the lease lifecycle cannot end up writing
      # to a different channel than the spawn it belongs to.
      def run_child(prompt, parent, on_stream_started: nil)
        isolation.hold(@name, journal:) do |worker_env|
          build_child(parent, worker_env).answered { |child| child.ask(prompt, on_stream_started:) }
        end
      end

      def build_child(parent, worker_env) = @builder.build(parent, ceiling: @max_depth - 1, worker_env:)

      def policy = @builder.policy

      # {Lineage} writes the :spawn and :message events; the causal-edge and
      # correlation-join reasoning lives there. Memoized rather than built in
      # #initialize only to keep the wiring point within its Metrics budget.
      # Late construction is safe, but no longer because Lineage is pure -- it
      # now carries the adoption count that keeps two live actors' addresses
      # apart. It is safe because this memo is the ONE Lineage a Subagent ever
      # has, so every actor it launches counts off the same sequence; a second
      # Subagent would be a second count.
      def lineage = @lineage ||= Lineage.new(policy:, log: @log, observer: lineage_observer)

      # An actor's lifecycle rides the journal: every {Lineage} event is
      # promoted to a {Telemetry::Message}, whose kind/digest/to/causal_parents
      # shape is what {StatusFeed}'s fleet field consumes. One-shot keeps the
      # plain observer -- its records already ride the tool_result and the
      # scribe, and existing specs pin its journal contents.
      def lineage_observer = @mode == :actor ? method(:journal_lifecycle) : observer

      def journal_lifecycle(event)
        journal << Telemetry::Message.from_event(event)
        observer.call(event)
      end

      # Mode fails loudly here: a mistyped mode must not silently fall through
      # to one-shot.
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

      # The seam's collaborators, passed through untouched -- only
      # {#parent_timeline} needs the thunk-or-value reading above.
      delegate :journal, :observer, :supervisor, :isolation, to: :@seam
    end

    # A subagent as an ordinary tool: possessing it is the authorization to
    # spawn a child Agent whose only trace in the parent's Timeline is its final
    # result, returned as an ordinary `tool_result`. The lineage events, the
    # shared-Store/separate-Timeline split and the transitive ceiling are in
    # ARCHITECTURE.md, "Subagent, Supervisor, and isolation".
    #
    # `Seam#parent` is a live HANDLE (a Timeline, or a `-> Timeline` thunk since
    # the toolset is built before the Agent) -- the one collaborator the render
    # chain cannot supply, because the parent head is only known at the instant
    # of the call. The shared Store rides ON that handle rather than being
    # injected beside it, so the two can never silently desync.
    #
    # The dispatch duck stays the Session a tool receives, which this tool does
    # not read: everything it needs was injected, so the ToolRunner and the
    # Session interface are untouched.
    #
    # {ChildBuilder} owns what a child IS; this class decides WHEN one may spawn
    # -- depth, mode, supervisor presence. On the ceiling, the half worth
    # restating here: a descended copy takes `min(its own, this one - 1)`, so
    # decrementing terminates the chain and `min` keeps a descendant's tighter
    # ceiling from being RAISED, which would be capability escalation.
    class Subagent < Tool
      # Reopened rather than nested mid-body: the split keeps each class body
      # within Metrics/ClassLength instead of loosening it.

      # ONE frozen object, not a fresh `ChainWriter::Null.new` per default:
      # Data's `==` is member-wise, so a per-default instance made
      # `Seam.new(**three) == Seam.new(**three)` FALSE -- a value whose equality
      # depends on which member the caller let default. Sharing is safe because
      # it holds no state.
      #
      # It lives on {Subagent}, not inside the `Data.define` block: a constant
      # written in that block lands in the ENCLOSING module rather than on the
      # Data class, and the block's own constant lookup is lexical from here.
      NO_OBSERVER = Event::ChainWriter::Null.new.freeze

      # The gate a child runs behind when nothing wired one. Shared and frozen
      # for {NO_OBSERVER}'s reason.
      #
      # APPROVING rather than denying, deliberately against
      # {Effect::Handler::Gate}'s own fail-closed default: a child spawned by a
      # harness that never wired a queue has no surface to answer a question, so
      # the roles the harness spawns UNATTENDED would park or refuse forever.
      # Absence means "this seam was never taught about a gate", not "deny"; a
      # caller that wants the session's gate passes it.
      UNGATED = Effect::Handler::Gate::ApproveAll.new.freeze

      # The path axis a seam was never taught about: nothing is sensitive, which
      # is byte-for-byte what a child did before the path boundary existed.
      # Shared for {NO_OBSERVER}'s equality reason.
      #
      # `lain.rb` loads `lain/sensitivity` well before `lain/tools`, so unlike
      # `mode/resolution.rb`'s deferred lookups this one may resolve eagerly in
      # the class body.
      UNJUDGED = Sensitivity::Policy::Null.instance

      # The refusal SENTENCE a seam was never taught about: whatever
      # {Effect::Handler::Gate} says on its own.
      #
      # A THUNK, like `context_factory` and unlike the Null objects above, for
      # that member's reason: the live one reads a {CLI::Switchboard} that does
      # not exist when the seam is built. Resolved once per child chain in
      # {ChildBuilder#gated}, not per call -- the sentence turns on whether a
      # human is attached, fixed for a session's whole life, where the policy
      # beside it flips with `/mode`.
      #
      # NOT `Sensitivity#denial`, which is a different message about a different
      # axis: that one answers for a path that may not be touched at all, this
      # one for a call that COULD have been approved by a human who is not
      # there. The word is taken twice; read which object is being asked.
      GENERIC_DENIAL = -> { Effect::Handler::Gate::DENIAL }

      # The ask-the-human seam a spawn was never taught about: there is no
      # queue and no desktop for a question to reach, at ANY depth an
      # escalation might relay through, so it enrols an {AskHuman::Unattended}
      # rather than a bare {AskHuman} -- the refusal a spawn under it gets is
      # immediate and names why, instead of writing a Q that parks forever
      # with nobody able to see it. The registration stays
      # {AskHuman::Directory::Unheld}: nothing is ever outstanding to route an
      # answer back to.
      #
      # NOT a sanctioned production state -- the exe always passes the run's
      # own askers, wired to a real queue. It duplicates
      # {CLI::Wiring::Askers.unwired} because `lain.rb` loads `lain/cli` before
      # `lain/tools`, so this file cannot name that class -- and neither should
      # it: a spawn asks for an enrolment, not for the CLI's way of making one.
      #
      # A module rather than an instance, for {NO_OBSERVER}'s equality reason.
      module NoAskers
        # The same two halves {CLI::Wiring::Askers::Enrolled} carries: the
        # child's own asker, and what its lifetime owner `deregister`s.
        Enrolled = Data.define(:asker, :registration)

        # `**` and not `agent:`, because there is nobody to name an asker TO.
        # `text: AskHuman::Unattended::NO_MAILBOX` rather than the class
        # default: this seam was never wired to a queue, which is not what
        # `--non-interactive` means, so the DEFAULT wording (accurate for
        # {CLI::Wiring::Askers#asker_over}'s own case) would state a false
        # reason here.
        def self.enrol(parent, **)
          asker = AskHuman::Unattended.new(parent:, text: AskHuman::Unattended::NO_MAILBOX)
          Enrolled.new(asker:, registration: AskHuman::Directory::Unheld)
        end

        def self.inspect = "Lain::Tools::Subagent::NoAskers"
        def self.to_s = inspect
      end

      # A lease a dispatch could not give back. Its own record because the
      # tolerance below must not be silent: the checkout is still on disk, it
      # will defeat the next acquire at that path, and `worker_key` is how a
      # human finds it. {Stagger}'s records are the shape -- a tool-local Data
      # on the tool's own journal.
      LeaseNotReclaimed = Data.define(:worker_key, :error) do
        include Telemetry::Journalable

        def initialize(worker_key:, error:)
          super(worker_key: worker_key.to_s.dup.freeze, error: error.to_s.dup.freeze)
        end
      end

      # Where a child's execution environment is leased FROM, and how the
      # workers leasing it are named. The two travel as one object because the
      # NAME is what a backend keys its resource on: {Isolation::Worktree}
      # derives a checkout path from the worker id and refuses a path a live
      # lease already holds, so an id handed out twice is a refused spawn or a
      # shared working tree, depending on which backend the run wired. The
      # backend arrives INJECTED -- a run resolves exactly one, and the
      # {Supervisor} is handed that same instance -- because two backends over
      # one project each allocate from state the other cannot see.
      #
      # ONE PER SEAM, which is one per run, and that is what makes the sequence
      # correct rather than merely monotonic. A nested spawn's tool is a
      # {Subagent#descend} copy built from `Seam#with`, and {Skill::RoleSpawn}
      # builds a FRESH Subagent per call over the seam it holds -- so parent,
      # child, grandchild and two concurrent role spawns all draw from this one
      # sequence. A counter owned by the tool instead would hand two of them the
      # same number, since each of those tools is a different object that never
      # meets the others.
      #
      # The SPELLING of the id is not here: {Supervisor} numbers the actors an
      # operator adopts off a sequence this one cannot see, and the two lanes
      # must not be able to name one resource, so {Isolation::WorkerId} owns
      # both spellings and the proof that they cannot meet. This object owns
      # only the sequence its own lane counts along.
      #
      # Monitor-guarded because {Subagent#fan_out} dispatches siblings
      # concurrently: two fibers really are inside `#hold` at once, and `+= 1`
      # is a read and a write with a suspension point available between them.
      class Leases
        # @param backend [#acquire] the {Isolation} backend a dispatch leases
        #   from; the shared-process baseline by default, whose lease is
        #   {WorkerEnv.default} and whose release reclaims nothing -- which is
        #   what lets every spawn lease unconditionally
        def initialize(backend: Isolation::Null.new)
          @backend = backend
          @monitor = Monitor.new
          @count = 0
        end

        # One dispatch's whole lease lifetime: mint a worker, acquire, run the
        # block under the leased environment, give it back.
        #
        # `ensure` and not `rescue StandardError`, because a cancelled dispatch
        # raises `Async::Stop`, which is not a StandardError, and a child
        # cancelled mid-ask has left its checkout as unreachable as one that
        # returned. `&.` covers the acquire itself refusing, which provisioned
        # nothing to reclaim.
        #
        # @param role [String] what this worker is for, so a checkout left
        #   behind names the spawn it belonged to
        # @param journal [#<<] where a failed reclaim is recorded
        # @yieldparam worker_env [WorkerEnv] the leased cwd and env
        # @return whatever the block returns
        def hold(role, journal:)
          worker = Isolation::WorkerId.spawned(role:, ordinal: next_ordinal)
          lease = @backend.acquire(worker.to_s)
          yield(lease.worker_env)
        ensure
          reclaim(lease, worker, journal)
        end

        private

        # A teardown that cannot reclaim must not eat a completed child's
        # answer. {Isolation::Worktree#remove} raises deliberately rather than
        # leave a checkout standing, and `Tool#call` does not rescue -- so a
        # raise on the way out of a finished dispatch hands the parent the
        # teardown failure in place of work it has already paid for.
        # {Supervisor#reap} carries the same tolerance at the same shape of
        # seam: attempt it, then let the record say what happened.
        def reclaim(lease, worker, journal)
          lease&.release
        rescue StandardError => e
          journal << LeaseNotReclaimed.new(worker_key: worker, error: e.message)
        end

        # Monitor-guarded: {Subagent#fan_out} dispatches siblings concurrently,
        # so two fibers really are inside this at once and `+= 1` is a read and
        # a write with a suspension point available between them.
        def next_ordinal = @monitor.synchronize { @count += 1 }
      end

      # The isolation a seam was never taught about: the shared-process
      # baseline, so a spawn over an unwired seam resolves its paths exactly
      # where it did before a lease was ever taken.
      #
      # Shared for {NO_OBSERVER}'s equality reason, and NOT frozen for a reason
      # of its own: it owns a worker-id sequence, and a frozen counter cannot
      # count. Sharing one sequence across every unwired seam costs nothing --
      # {Isolation::Null} ignores the id it is handed.
      NO_ISOLATION = Leases.new

      # What a child spawn is built OVER: the collaborators every spawn needs
      # and no single spawn chooses. Three adopters ({Subagent},
      # {ChildBuilder}, {Skill::RoleSpawn}) took them as loose keywords, so a
      # new collaborator meant four edits that could be three-quarters done;
      # as one value it is one member and one wiring line.
      #
      # It nests HERE, under the class all three adopters build, and not as a
      # top-level `Lain::Spawn::Seam` -- that would sit a hand's breadth from
      # {Bench::SpawnSeam}, a DIFFERENT duck
      # (`call(journal:, **spawn_opts) -> Agent`).
      #
      # `toolset` is deliberately NOT a member: each adopter attenuates over a
      # different base union, so it is per-caller state, not shared seam state.
      #
      # Frozen like every Data, but NOT `Ractor.shareable?` and not aspiring to
      # be: `context_factory` and `denial` are callables, a provider is a live
      # client, and `parent` is a thunk or a Timeline. A new member should say
      # which direction it moves that claim; the current ones move it nowhere
      # new. This bundles collaborators -- it is not a value in the
      # {Event}/{Canonical} sense.
      Seam = Data.define(:provider, :context_factory, :parent, :journal, :supervisor, :observer,
                         :gate_policy, :permits, :askers, :sensitivity, :denial, :isolation, :escalation) do
        # Everything after `parent` defaults to its Null object; {UNGATED} and
        # {Mode::Posture::Permits::All} are the two that say "no posture has
        # been bound to this seam". The first three stay required, so Data's own
        # missing-keyword error is the loud failure, unwritten.
        #
        # `escalation` defaults to `[AskHuman::HUMAN]`: absent a spawn, `parent`
        # IS the run's own chat, so a question asked FROM it need go no further
        # once it is addressed there. A seam a spawn built over
        # ({ChildBuilder#own_chain}) replaces this with whatever `parent`'s OWN
        # further hops are, so a grandchild's relay carries the whole road
        # rather than only its immediate parent's name.
        def initialize(provider:, context_factory:, parent:, journal: Channel::Null.instance,
                       supervisor: Supervisor::Null, observer: NO_OBSERVER,
                       gate_policy: UNGATED, permits: Mode::Posture::Permits::All, askers: NoAskers,
                       sensitivity: UNJUDGED, denial: GENERIC_DENIAL, isolation: NO_ISOLATION,
                       escalation: [AskHuman::HUMAN].freeze)
          super
        end

        # `seam:` or the loose members, never both -- honoring both would mean
        # silently preferring one and dropping the other.
        #
        # A stray keyword is a TYPO, not a conflict, and the two must not be
        # confused: reporting `:max_dept` as "you passed a seam AND its members"
        # would send the reader hunting for a member they never passed. So the
        # seam path partitions first and says what Ruby says on the loose path.
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

      # What a child IS: the union it renders, the Agent over it, the handler
      # enforcing the posture. Parent-agnostic by construction -- `parent`
      # arrives per {#build}, never at initialize -- so one builder serves every
      # spawn without carrying spawn-specific state.
      class ChildBuilder
        # A child has TWO lifetimes to answer for: the Agent the caller runs,
        # and the {AskHuman::Directory::Registration}, which nothing but a
        # `deregister` releases. Holding the pair is what lets this own the
        # release, in the two shapes below rather than as the same `ensure`
        # copied into {Subagent}.
        #
        # Both are `ensure`, never `rescue StandardError`: a cancelled dispatch
        # raises `Async::Stop`, which is not a StandardError, and a child
        # cancelled mid-ask is as unreachable as one that returned.
        Child = Data.define(:agent, :registration) do
          # A one-shot child's lifetime IS the dispatch, so the release lands
          # on every exit from it. `timeline` is read AFTER the block: the
          # caller wants the settled head, not the one the child started from.
          def answered
            response = yield(agent)
            [agent.timeline, response]
          ensure
            registration.deregister
          end

          # An actor's lifetime outlives the launch, so the registration goes
          # WITH it -- unless no actor comes out at all, in which case the
          # release happens here or never: the Actor reference goes with the
          # raise, so nothing else could ever hold this.
          def launched
            actor = nil
            actor = yield(agent, registration)
          ensure
            registration.deregister unless actor
          end
        end

        # One spawn's own chain: where the child STARTS, how to read its live
        # head, how its committed turns reach the session record, and the
        # whole road a question the child asks travels before it reaches a
        # human -- the parent's own correlation first, then wherever THAT
        # parent's own questions would go, which {#own_chain} reads off the
        # seam being spawned INTO rather than recomputing. The four travel
        # together because the asker needs the other three before the Agent
        # that owns them exists.
        Chain = Data.define(:base, :timeline, :feed, :escalation) do
          # A correlation is a chain's ROOT digest, and an `:inherit` spawn is
          # `parent.fork`, so child and parent share a root PERMANENTLY -- the
          # child's own future correlation is therefore the SAME STRING as
          # `parent`'s, computable here from `base` before the child's own
          # Timeline exists (a fork's root never changes as later turns land
          # on it). Left uncollapsed, a hop would address a chain to ITSELF:
          # the child's own Q writes `from:` that string and {#asking_handle}
          # would hand it right back as `to:`. `base` carries no head at all
          # under `fresh`/`sibling_template` (a brand-new root), so
          # `correlation_of` reads nil there and nothing collapses -- the
          # ordinary, already-correct case.
          #
          # `chunk_while` collapses every RUN of equal addresses to one --
          # not just the leading self-address, because an `:inherit` chain
          # several spawns deep can repeat the SAME root at every hop -- and
          # `drop(1)` removes the leading entry, which is always the child's
          # own identity rather than an address the record should carry.
          #
          # A class method rather than an instance one: {ChildBuilder#own_chain}
          # needs this value BEFORE a Chain exists to call it on.
          def self.escalation_road(base, parent, beyond)
            road = [Event::ChainWriter.correlation_of(base), Event::ChainWriter.correlation_of(parent), *beyond]
            road.chunk_while { |a, b| a == b }.map(&:first).drop(1)
          end

          # What a child's asker is handed instead of a bare timeline thunk:
          # the same live head, the promotion that has to happen before a
          # question cites it, and the escalation road so the Q names who it
          # was actually put to and {AskHuman} can relay it the rest of the
          # way without ever touching an ancestor's own dispatch.
          # {Middleware::JournalTurns} promotes when an iteration RETURNS, and
          # a parked ask never returns from the one it asked in -- so
          # unpromoted, the question named a turn no record carried and the
          # session refused to fork or resume.
          def asking_handle
            AskHuman::Parent.new(read: timeline, settle: method(:promote),
                                 to: escalation.first, escalation: escalation.drop(1))
          end

          # And what a NESTED spawn's seam is handed, for the same defect one
          # record up: a grandchild's :spawn cites the child's live head
          # exactly as a question cites its asker's, and a grandchild parked
          # mid-iteration leaves the CHILD's iteration unreturned too. A thunk
          # rather than the handle above, because {Seam}'s `parent` member is a
          # Timeline or a thunk and this seam gains no new duck.
          def spawning_handle = -> { settled }

          # ONE read, promoted and then cited: a record names the head that was
          # promoted because it is the same value, not because nothing could
          # advance between two reads.
          def settled = timeline.call.tap { |live| promote(live) }

          # Idempotent through {TurnFeed}'s stop digest, which advances per
          # turn: the catch-up the iteration runs afterwards re-walks nothing,
          # so this cannot double-record and cannot re-enter the middleware it
          # shares a feed with.
          def promote(live) = feed.catch_up(live)
        end

        attr_reader :policy, :toolset

        # `name` is what a human is TOLD is asking when this child puts a
        # question to them, so a role spawn announces as "researcher" rather
        # than as a 71-character correlation.
        def initialize(seam:, toolset:, policy:, budget:, persona: Role::Persona::Null, name: "subagent")
          @seam = seam
          @toolset = toolset
          @policy = policy
          @budget = budget
          @persona = persona
          @name = name
        end

        # Every copy gets the spawn wiring verbatim, the seam's observer and
        # supervisor included: a grandchild's events must reach the same scribe
        # or nested spawns vanish from the session record, and its actors the
        # same reactor.
        #
        # `parent` and `escalation` are the two members a copy does NOT
        # inherit: `parent` points at the CHILD, so the grandchild's lineage
        # names the child's live head, and `escalation` becomes the CHILD's
        # OWN full road ({Chain#escalation}, computed by the `#own_chain` call
        # that is spawning THIS child) rather than staying `@seam.escalation`
        # -- the road as it looked one hop further out. Passing the unchanged
        # value here would let a grandchild's question skip straight past its
        # own parent to wherever ITS grandparent's mailbox is.
        def config(parent:, escalation:)
          { seam: @seam.with(parent:, escalation:), toolset: @toolset, policy: @policy,
            budget: @budget, persona: @persona }
        end

        # `child` is late-bound through the thunk exactly as the exe wires the
        # tool itself: the union must exist before the Agent, but a
        # grandchild's lineage must name the child's LIVE head at its own spawn
        # instant, and the child's asker must attribute its questions to the
        # child's own chain rather than to the parent's.
        #
        # That handle is the ONE thing the asker and the union share, which is
        # why enrolment happens here rather than at the tool: nothing above this
        # method can name a child that does not exist yet.
        def build(parent, ceiling:, worker_env: WorkerEnv.default)
          child = nil
          chain = own_chain(parent) { child.timeline }
          union = child_union(chain.spawning_handle, chain.escalation, ceiling)
          spawned(@seam.askers.enrol(chain.asking_handle, agent: @name), chain, union, worker_env)
            .tap { |built| child = built.agent }
        end

        private

        # One spawn's own chain, built HERE rather than at the Agent, because
        # the asker is enrolled before the Agent exists and needs the feed.
        # Per SPAWN and never memoized on the builder: a fan-out runs sibling
        # spawns concurrently over one of these, so a shared feed would promote
        # one sibling's turns against another's stop digest.
        #
        # Hoisting the base above {#permitted}'s refusal and the attenuation is
        # free because every {Tool::SpawnPolicy::PrefixStrategy} builds one
        # purely -- `Timeline.empty` or an O(1) `parent.fork` -- so a spawn that
        # goes on to raise merely discards it.
        #
        # The escalation road: `parent`'s own correlation first -- the chain
        # being spawned FROM, not the child's own, exactly as {Lineage#message}
        # names its `to:`, so a child's question and the spawn's own result
        # message address the same identity by the same derivation -- then
        # `@seam.escalation`, which is `parent`'s OWN further road (defaulted
        # to `[HUMAN]` when `parent` is the run's own chat, or set by an
        # ENCLOSING `#own_chain` call when `parent` is itself a spawned child;
        # see {ChildBuilder#config}). {Chain.escalation_road} collapses a run
        # this may create for an `:inherit` spawn; read here rather than
        # inside {Chain#asking_handle} because that method's receiver is the
        # CHILD's own chain, which has no way back to the parent it was
        # spawned under.
        def own_chain(parent, &timeline)
          base = @policy.prefix.base_timeline(parent:, store: parent.store)
          Chain.new(base:, timeline:, escalation: Chain.escalation_road(base, parent, @seam.escalation),
                    feed: TurnFeed.new(observer: @seam.observer, base: base.head_digest))
        end

        # A spawn that raises past this point ({NoCapability}, a Context that
        # will not render) leaves no lifetime for anyone to hang a `deregister`
        # on, and retention runs from `register` to `deregister` and nothing
        # else -- so this method is the only place that release can live.
        def spawned(enrolled, chain, union, worker_env)
          child = nil
          asker = enrolled.asker
          allowed = granted(permitted(@policy.attenuate(union)), asker)
          child = Child.new(agent: spawn_agent(chain, granted(union, asker), allowed, worker_env),
                            registration: enrolled.registration)
        ensure
          # Keyed on the handle rather than `rescue StandardError`, so a
          # CANCELLED spawn releases too: `Async::Stop` is not a StandardError.
          enrolled.registration.deregister unless child
        end

        # The child's own asker, granted ON TOP of the attenuated set rather
        # than folded into the union it attenuates from: no role in the catalog
        # names `ask_human` in its `only`-set, so a set that went through
        # {Tool::SpawnPolicy#attenuate} would have dropped it. {#permitted} runs
        # BEFORE this -- "the posture permits none of the SPAWN's tools" is a
        # wiring error whether or not the child could still ask about it.
        #
        # The grant is a default with CONDITIONS, and both must survive a
        # future edit. The SESSION posture governs it: a rung that stopped
        # permitting `ask_human` MUTES every child rather than being quietly
        # granted past. The ROLE governs it too, through
        # {Tool::SpawnPolicy}'s `unattended` -- an arm that answers with nobody
        # minding it holds no tool that can block on a human, and `only:` cannot
        # say so from inside a set this grant is deliberately outside of.
        #
        # REPLACING rather than appending, and the strip is UNCONDITIONAL where
        # the grant is not. A union that already holds an `ask_human` holds the
        # PARENT's, whose questions would be attributed to the parent's chain
        # and whose promise the parent's {AskHuman::Outstanding} holds. So an
        # early return for the muted case would leave the PARENT's asker
        # standing in the dispatch union -- reachable, and under `handler_union`
        # rendered, to the very child the posture just muted.
        def granted(set, asker)
          own = grants_own_asker?(asker) ? [asker] : []
          Toolset.new(set.reject { |tool| tool.name == asker.name } + own)
        end

        # Two conditions refusing for different reasons: the SESSION posture is
        # the rung the whole run stands on, `unattended` is the ROLE's own claim
        # that it answers with nobody minding it. Either alone is enough to
        # withhold -- both say a question this child asked would reach no one.
        def grants_own_asker?(asker)
          !@policy.unattended && @seam.permits.include?(asker.name)
        end

        # The child's capability set: the spawn policy's attenuation, then the
        # SESSION posture's -- a `plan`-mode parent must not hand a child the
        # `bash` it does not itself hold, which four shipped roles would
        # otherwise take.
        #
        # An INTERSECTION rather than {Mode::Posture#attenuate}: that goes
        # through {Toolset#only}, which raises on a name the set does not hold,
        # so asking `plan` to attenuate a `:merge_resolver` child's four tools
        # would die on the nine read-only names the child never held. A spawn
        # under a restrictive posture must ANSWER "here is what you may hold",
        # not blow up. `Permits#include?` asks one name at a time for exactly
        # this reason.
        #
        # == Read PER SPAWN, where `gate_policy` is read per CALL
        #
        # The two axes a posture governs do not have the same liveness, and the
        # difference is observable. A child renders a frozen {Toolset} once,
        # here; the gate answers through a live policy on every call. A
        # `:one_shot` child cannot straddle a `/mode` flip, but an `:actor`
        # adopted onto the {Supervisor} can, and it keeps the set it was
        # rendered -- and since `plan`'s `DenyAll` intercepts only TIER 3, that
        # actor's `edit_file` still runs. "Plan mutates nothing" is therefore a
        # claim about the session and about children spawned AFTER the flip, not
        # about one already running. Making it true for those too needs a live
        # toolset slot in the child ({CLI::Switchboard::LiveToolset}'s shape).
        def permitted(allowed)
          permitted = allowed.only(*allowed.names.select { |name| @seam.permits.include?(name) })
          raise NoCapability, no_capability(allowed) if permitted.empty?

          permitted
        end

        # A child with nothing at all is a wiring error, not a tighter child.
        # Unreachable from the shipped catalog, so a reader who hits it paired a
        # custom `only:` with a posture sharing no name with it -- hence naming
        # both halves, since either could be the one to change.
        def no_capability(allowed)
          "a #{@seam.permits} session permits none of the spawn's tools " \
            "(#{allowed.names.join(", ")}), so the child would hold nothing"
        end

        # Every Subagent in the injected union is replaced by a descended copy:
        # handing the SAME instances down would let a nested spawn keep its
        # constructing ceiling, and recursion would never terminate via the cap.
        # The copy's schema bytes are identical, so the rendered tools block --
        # and with it the cache prefix -- is unchanged.
        def child_union(parent_handle, escalation, ceiling)
          Toolset.new(@toolset.map do |tool|
            tool.is_a?(Subagent) ? tool.descend(parent: parent_handle, escalation:, ceiling:) : tool
          end)
        end

        # A fresh {Session} per spawn -- never {Session::Null} -- so a
        # write-capable child can satisfy EditFile's read-before-write contract
        # against its OWN read-set. Built here, not memoized: a builder is
        # reused across sibling spawns, so a memoized Session would leak one
        # sibling's reads into the next. This builder is never handed the
        # parent's Session, so the child's read-set starts empty by
        # construction.
        def spawn_agent(chain, union, allowed, worker_env)
          Agent.new(
            provider: @seam.provider, context: child_context,
            toolset: @policy.posture.rendered_toolset(union:, allowed:), handler: child_handler(union, allowed),
            timeline: chain.base, turn_middleware: recorded_turns(chain),
            session: Session.new(worker_env:), budget: @budget, journal: @seam.journal
          )
        end

        # The child's turns, into the session record, per ITERATION rather than
        # per settle: a child's `ask_human` question is written DURING an
        # iteration and cites the head that iteration committed, so a feed that
        # waited for the child to settle would record the turn AFTER the
        # question naming it. The timeline rides a thunk because the turn env
        # carries the PRE-step snapshot, and is late-bound because the
        # middleware must exist before the Agent that runs it.
        #
        # Per-iteration is still not often enough for a question that PARKS --
        # that iteration never returns -- which is what {Chain#asking_handle}
        # covers, on the same feed.
        def recorded_turns(chain)
          Middleware::Stack.new([Middleware::JournalTurns.new(scribe: chain.feed, timeline: chain.timeline)])
        end

        # Two composed reshapes over the factory's Context: PERSONA first, then
        # the PREFIX strategy. Persona is the inner reshape so the role's marked
        # bulk is what a fresh child renders, and a strategy that rewrites
        # system sees the persona'd context rather than the bare factory one.
        def child_context
          @policy.prefix.child_context(@persona.child_context(@seam.context_factory.call), journal: @seam.journal)
        end

        # `schema` renders the attenuated set, so a plain executor suffices;
        # `handler_union` renders the shared union, so the RefusingHandler
        # enforces the `only`-set the model can see but must not use. Both
        # dispatch against the DESCENDED union, never the injected toolset, so a
        # permitted nested subagent runs at its decremented ceiling. Both run
        # behind {#gated}.
        #
        # Under `handler_union` a `plan`-mode child is SHOWN tools the posture
        # forbids it, which reads against {Mode::Posture}'s note that plan is
        # safe because "the rendered schema simply does not contain
        # `edit_file`". That note describes the DEFAULT posture's mechanism, not
        # the guarantee. What plan promises is that the child cannot DISPATCH a
        # mutating tool: `schema` withholds the name, `handler_union` shows it
        # and refuses it, and neither can dispatch it.
        def child_handler(union, allowed)
          return gated(Effect::Handler::Live.new(toolset: allowed)) unless @policy.posture.refuses_over_union?

          RefusingHandler.new(allowed: allowed.names, journal: @seam.journal,
                              inner: gated(Effect::Handler::Live.new(toolset: union)))
        end

        # The session's approval gate in front of the child's executor: a child
        # holding a tier-3 tool asks the SAME policy its parent asks, so `bash`
        # is not ungated merely because a subagent is the one calling it. A
        # denial arrives as an is_error {Tool::Result}, never a raise, which is
        # what keeps the child's loop running rather than wedging on a refusal.
        #
        # Composed INSIDE the RefusingHandler above, not around it, and the
        # order is the point: a call the child was never attenuated to must be
        # refused outright, not parked for a human who would then watch it be
        # refused anyway. Under `schema` there is no refusal layer to sit behind
        # -- a name outside the rendered set resolves to no tool, so the gate
        # declines and {Effect::Handler::Live} reports the unknown tool.
        #
        # BOTH gating axes ride the seam, and the sensitivity half is not
        # optional: a child gate built without the session's sensitivity policy
        # would let a subagent read a path its parent must ask about -- a
        # privilege inversion, since the child is the LESS supervised of the
        # two. Same reason it is here rather than only in {CLI::Switchboard#gate}.
        # It is read per call through the same board thunk `gate_policy`
        # travels, so the two can never resolve to different sessions.
        #
        # What a refusal SAYS travels the same seam for the same reason: a child
        # gated by its parent's policy but told the generic "approval denied"
        # reads that as a human's no, invites a retry, and retries for the life
        # of a run where nobody can ever answer. Resolved HERE, once per child
        # chain, because the board exists by spawn time and cannot change after.
        def gated(inner)
          Effect::Handler::Sensitivity.new(
            sensitivity: @seam.sensitivity, journal: @seam.journal,
            inner: Effect::Handler::Gate.new(policy: @seam.gate_policy, sensitivity: @seam.sensitivity, inner:,
                                             denial: @seam.denial.call)
          )
        end
      end
    end
  end
end

# These children reopen Subagent, so they load after the class body. Log leads:
# Lineage's `log:` default names Log::Null.
require_relative "subagent/log"
require_relative "subagent/lineage"
require_relative "subagent/turn_feed"
require_relative "subagent/refusing_handler"
require_relative "subagent/actor"
require_relative "subagent/stagger"
