# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/module/delegation"

module Lain
  module Tools
    # The one field every model-facing spawner's input carries, and the words
    # the model reads it by. Included by {Subagent::Input} and
    # {Subagent::Choice::Input}.
    #
    # A Concern, not a shared superclass, because the two are SIBLINGS rather
    # than a specialisation of one another: Choice's input adds `role` BESIDE
    # this field without refining anything about it, and neither owns the other.
    # Inheriting one from the other would also make the enclosing tool's
    # identity look like a subtype of the other tool's, which it is not.
    #
    # Why it is shared at all: a rendered schema's BYTES are the prompt-cache
    # key. Two spawners describing the same field in different words cost a
    # cache miss on every call they appear in, and the difference reads exactly
    # like a deliberate schema change to anyone diffing two runs -- so an
    # improvement made to one and not the other is both a regression and an
    # invisible one. One spelling, one place to improve it.
    module Tasked
      extend ActiveSupport::Concern

      # Model-facing, and per {Tool::Input.field} the highest-leverage words in
      # the schema.
      TASK = "The task for the subagent to carry out on its own."

      included do
        field :prompt, :string, required: true, description: TASK
      end
    end

    class Subagent < Tool # rubocop:disable Style/Documentation -- doc lives on the reopen below; see .rubocop.yml's note
      # What the model calls a spawner, whatever roles it offers. NOT the same
      # word as {CLI::Wiring::ToolsetBuild::SPAWN_REQUESTER} or
      # {CLI::FleetWindows::FALLBACK_ROLE}, which happen to spell it the same:
      # those name who a HUMAN is told is asking, the axis `announces_as` keeps
      # separate from this one on purpose.
      NAME = "subagent"

      # Just the task. Prefix strategy, attenuation posture and `only`-set are
      # construction-time config, so what a subagent may do is never a per-call
      # decision the model negotiates.
      class Input < Tool::Input
        include Tasked
      end

      input_model Input

      # Closed and loud: a mode outside this set raises at construction.
      MODES = %i[one_shot actor].freeze

      attr_reader :name

      # The {Seam} this tool spawns over, and the union a child attenuates FROM.
      # Exposed so the bench asks the capability layering directly rather than
      # reaching two deep into {ChildBuilder}'s private ivars for it.
      attr_reader :seam

      def attenuates_from = @builder.toolset

      # What a spawn from this tool is granted, read by whoever grants a role
      # rather than by the spawn: how many levels it may still spawn below
      # itself, the policy its child is attenuated by, and the budget that
      # child's loop runs under.
      attr_reader :max_depth

      def policy = @builder.policy

      def budget = @builder.budget

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
                     max_depth: 1, name: NAME, announces_as: name, mode: :one_shot,
                     log: Log::Null, persona: Role::Persona::Null, answer: ANSWER, **spawn_over)
        super()
        @seam = Seam.resolve(seam, **spawn_over)
        @announces_as = announces_as
        @answer = answer
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
      #
      # `worker_env` has no default: an actor handed none would run its tools
      # in the process's own directory, the tree the run was started in. An
      # adopter hands it the environment its lease was cut with.
      def launch_actor(prompt, worker_env:, parent: parent_timeline)
        # Per launch: the floor note has no lifecycle exemption, so an
        # actor-mode sibling under the floor is reported too.
        policy.prefix.journal_floor(journal)
        # The actor holds its child's asker registration because it holds the
        # child's LIFETIME: `Supervisor#stop` farewells every row, so a
        # `deregister` there rides the same lease teardown that reaps the fiber.
        # {ChildBuilder::Child} owns the case where no actor comes out at all.
        build_child(parent, worker_env).launched do |agent, registration, tools|
          Actor.new(agent:, registration:, lineage:, parent:, journal:, answer: @answer,
                    worker: Isolation::SelfSync.worker(agent, tools:)).launch(prompt)
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
                                 announces_as: @announces_as, mode: @mode, log: @log, answer: @answer)
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

      # Re-entrant by construction: the record rides a {Lineage::OneShot} held
      # in a LOCAL across the child's IO yield, so a sibling fan-out task
      # resuming mid-flight cannot make a completion name the wrong spawn or
      # child. The record IS the pair of events, and a reader watches them
      # through the seam's `observer:`.
      #
      # THE LEASE COMES FIRST, and the :spawn is written under it: a refused
      # acquire leaves no record of a child that never existed, and the
      # refusal is what the parent is given. Every spawn written is ended --
      # by its answer, or by the `failed` or `stopped` completion
      # {Lineage::OneShot#recording} writes on the way out.
      #
      # WHAT THE RECORD MEANS ON A BOUNDED SPAWN, since two fields change sense
      # and nothing else says so: the :message's `body["result"]` holds what the
      # parent was GIVEN, which is the child's own summary or the floor sentence
      # rather than the answer it first produced; and `"final"` names the head
      # AFTER the summarizing ask, because that ask is a real turn on the
      # child's Timeline. The full original answer is not lost -- it is a turn
      # on that Timeline, reachable from `"final"`.
      #
      # WHILE THE SEAM'S SCOPE CONFINES, the child is lent the scope's
      # environment in place of a lease, and its session is confined to the
      # same scope: under plan, a child's writes land in the spike. Read here,
      # where every one-shot spawn passes -- a tool call, a role skill, a
      # fan-out -- and once, so the lease and the session agree.
      def spawn_one_shot(prompt, on_stream_started: nil)
        # Per spawn, not per tool, so a fan-out's record shows WHICH spawns
        # ran un-cacheable.
        policy.prefix.journal_floor(journal)
        scope = @seam.scope.current
        Lineage::OneShot.new(lineage, parent_timeline, consumed: telemetry, journal:).recording do |record|
          Tool::Result.ok(finished(record, leased(record, prompt, scope:, on_stream_started:)).text)
        end
      end

      # A child the scope did not lend to -- one its caller lent a checkout of
      # its own -- keeps that checkout, so its session is not the scope's.
      def leased(record, prompt, scope:, on_stream_started:)
        lent = scope.lend(isolation)
        scope = Session::Unconfined if lent.equal?(isolation)
        lent.hold(@name, journal:) do |worker_env, sync, worker|
          progress = reporting(record.spawned(prompt), prompt, worker)
          child = build_child(record.parent, worker_env, scope, progress:)
          run_child(record.built(child), prompt, sync, on_stream_started:)
        end
      end

      # The live views' half of the same dispatch. It goes out under the lease
      # and after the :spawn, which is what lets the row name both the worker
      # the child's writes land in and the spawn a watcher addresses it by.
      def reporting(spawn, prompt, worker)
        Progress.new(spawn: spawn.digest, tee: telemetry)
                .dispatched(role: @announces_as, task: prompt, worker:)
      end

      # The answer, with what the lease's handback owes the parent folded in,
      # recorded as what the parent was given.
      def finished(record, held)
        timeline, response = held.value
        record.finished(timeline, held.delivered(response))
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
      #
      # The answer is bounded HERE, inside the block, for two reasons that
      # agree. It is the only place the child AGENT is in scope -- `answered`
      # hands back its Timeline, not itself -- and the summarizing ask has to
      # run while the child is still alive, under this lease and this
      # registration. It also leaves the `@last_*` write sequence untouched: a
      # second ask yields at the yield point this method ALREADY had, so no new
      # suspension appears between here and the one place those ivars are set.
      #
      # The self-sync runs HERE too, after the answer and before the lease's
      # reclaim, for the reason the bounding does: a conflicted rebase is put
      # to the child that made the commits, and only this block still holds
      # it live. A child that raised never reaches it, and its lease syncs the
      # checkout with nobody to ask before surrendering it.
      def run_child(child, prompt, sync, on_stream_started: nil)
        child.answered do |agent, tools|
          @answer.bounded(agent, refusing_malformed(agent.ask(prompt, on_stream_started:)), journal:)
                 .tap { sync.call(Isolation::SelfSync.worker(agent, tools:)) }
        end
      end

      # Checked before the bounding, so an envelope too large to deliver is not
      # first handed back to the child to summarize.
      #
      # `:malformed` names a reading, not a shape, and the parent is told WHICH
      # one: a provider fires it for a tool call written as prose AND for a turn
      # that said nothing at all. `#text` is what tells them apart here, the
      # same discriminator {Answer#undeliverable} already uses one call further
      # on, and it is enough because an envelope is never empty.
      def refusing_malformed(response)
        return response unless response.stop_reason == StopReason::MALFORMED

        raise MalformedAnswer, malformed_reading(response)
      end

      def malformed_reading(response)
        return "the child's turn said nothing at all, not an answer" if response.text.empty?

        "the child's turn was a tool call written as prose, not an answer"
      end

      def build_child(parent, worker_env, scope = @seam.scope.current, progress: Progress::Null)
        @builder.build(parent, ceiling: @max_depth - 1, worker_env:, scope:, progress:)
      end

      # {Lineage} writes the :spawn and :message events; the causal-edge and
      # correlation-join reasoning lives there. Memoized rather than built in
      # #initialize only to keep the wiring point within its Metrics budget.
      # Late construction is safe, but no longer because Lineage is pure -- it
      # now carries the adoption count that keeps two live actors' addresses
      # apart. It is safe because this memo is the ONE Lineage a Subagent ever
      # has, so every actor it launches counts off the same sequence; a second
      # Subagent would be a second count.
      #
      # Every {Lineage} event, an actor's lifecycle included, reaches the record
      # through the observer alone. In a chat that is the scribe, which writes
      # it as a {Telemetry::Message} and routes it through the tee to
      # {StatusFeed}'s fleet field; the seam's journal is the same session file,
      # so writing the event there too would record every transition twice.
      def lineage = @lineage ||= Lineage.new(policy:, log: @log, observer:, lane: isolation.lane.name)

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

      # The parent Timeline, live: the toolset is built before the Agent, so
      # the exe wiring hands a `-> { agent.timeline }` that {Lain.live} calls
      # at the instant of this read rather than at construction.
      def parent_timeline = Lain.live(@seam.parent)

      # The seam's collaborators, passed through untouched -- only
      # {#parent_timeline} needs the thunk-or-value reading above.
      delegate :journal, :telemetry, :observer, :supervisor, :isolation, to: :@seam
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

      # A spawn seam handed something other than a builder of a child's tool
      # stack. Named, and raised where the seam is built: the likeliest wrong
      # value is a stack or a lone middleware, and both answer `call`, so
      # unrefused they would fail only at the first spawn, deep inside it.
      class NotABuilder < ArgumentError; end

      # A one-shot child whose turn its provider read as malformed -- a tool
      # call written as prose, or a reply that said nothing at all -- has not
      # answered, whatever its text says. It is raised rather than returned so
      # the spawn ends the way every other child that did not answer ends: a
      # `failed` completion naming this class and carrying no "result", which is
      # what keeps it out of every reader of finished work, and an error result
      # for the parent. Which reading it was travels in the message.
      class MalformedAnswer < Error; end

      # The ask-the-human seam a spawn was never taught about: there is no
      # queue and no desktop for a question to reach, at ANY depth an
      # escalation might relay through, so it enrols an {AskHuman::Unattended}
      # rather than a bare {AskHuman} -- the refusal a spawn under it gets is
      # immediate and names why, instead of writing a Q that parks forever
      # with nobody able to see it. The registration stays
      # {AskHuman::Directory::Unheld}: nothing is ever outstanding to route an
      # answer back to.
      #
      # A chat wires the run's own askers, and this is what a spawn seam built
      # outside one gets. {CLI::EpicSubmit::Adjudication} NAMES it
      # rather than taking it from the {Seam} default, because there it is the
      # honest configuration: that command runs out of chat, so its children
      # really do have no queue and no directory anywhere -- which is what
      # {AskHuman::Unattended::NO_MAILBOX} states and why that wording exists.
      # A chat seam getting it by default is the case {Seam#initialize} says is
      # still open.
      #
      # It duplicates what {CLI::Wiring::Askers} would enrol rather than naming
      # that class: a spawn asks for an enrolment, not for the CLI's way of
      # making one.
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

      # The ceiling one child answer may occupy in the parent's context, in
      # bytes: roughly 4,000 tokens of prose, which is Anthropic's whole minimum
      # cacheable prefix. An answer past it is no longer a result the parent
      # reads alongside its own work -- it IS the parent's turn. And a parent
      # cannot drop a tool_result, so one oversized answer pins occupancy with
      # nothing compactable underneath it, which is the shape a live session was
      # measured stuck in.
      #
      # A FIXED figure, where the thing it protects is not: the harness knows
      # the live window through {ContextWindow}, and 16 KiB is ~2% of a 200k
      # window but about a third of the 8k one a local model is driven at. A
      # window-relative ceiling is the better answer and needs the model in
      # scope here, which a spawn does not have; until then this is deliberately
      # the conservative end, and `bounds:` is injectable for an arm that wants
      # its own.
      ANSWER_BOUND = Tool::Bounds::Artifact.new(limit: 16 * 1024)

      # How much of a failure's own message may ride into a refusal sentence and
      # an NDJSON line. An exception message is unbounded and is written by
      # whatever raised: a provider error carrying a response body, a
      # `JSON::ParserError` echoing its document, a `NoMethodError` inspecting a
      # large receiver. {Approval::Gate::Adjudicator}'s `note` clamps for this
      # reason and at this size -- the head is where the diagnosis is.
      MAX_FAILURE_REASON = 500

      # Where a parent can go instead when no summary could be delivered.
      # {Tool::Bounds::Artifact#message} refuses to build a refusal without
      # one -- advice naming nowhere to go leaves the model to re-issue the
      # same call and be refused identically.
      NARROWER_ASKS = ["spawn one subagent per part of the task",
                       "ask it for the specific finding you need"].freeze

      # That a child's answer did not fit ("answer_bounded" on the wire):
      # `outcome` is `summarized` when the child's own summary was delivered and
      # `floor` when none could be, with `reason` naming which of the several
      # ways that happened. Journaled for {Tool::SpawnPolicy}'s floor-note
      # reason, which this sits two lines away from at both spawn sites: a
      # decision this consequential must not be legible ONLY as English inside a
      # result the model consumes, or "how often does bounding fire, and how
      # often does it floor" costs a grep over prose.
      AnswerBounded = Data.define(:size, :limit, :outcome, :reason) do
        include Telemetry::Journalable

        # `-@` and not `#freeze`, because interpolation hands back a MUTABLE
        # String and a record must stay `Ractor.shareable?`.
        def initialize(size:, limit:, outcome:, reason: "")
          super(size:, limit:, outcome: -outcome.to_s, reason: -reason.to_s)
        end
      end

      # A child's answer, kept under {ANSWER_BOUND} by asking the CHILD to
      # summarize it. Its context already holds the answer, so that ask is the
      # cheapest summarizer available and the only one that cannot mistake what
      # the answer meant. Neither shape {Tool::Bounds} offers fits alone here:
      # truncating leaves an answer that reads complete and is wrong, and
      # refusing outright throws away work the run has already paid for.
      #
      # Everything it hands back is a real {Response} -- the child's own, with
      # its text replaced -- never a stand-in that answers only `text`. That
      # keeps `stop_reason`, `usage`, `model` and `id` intact for whoever reads
      # the record, keeps the value `Ractor.shareable?` (an interpolated String
      # on a bare Data is not), and leaves {ChildBuilder::Child#answered}'s
      # documented `[timeline, response]` seam a single type.
      Answer = Data.define(:bounds) do
        def initialize(bounds: ANSWER_BOUND)
          super
        end

        # @param agent [#ask] the child that gave the answer, still live
        # @param response [Response] what it answered
        # @param journal [#<<] where the bounding decision is recorded
        # @return [Response] the response itself when it fits, else the same
        #   response carrying what the parent is given instead
        def bounded(agent, response, journal: Channel::Null.instance)
          size = response.text.bytesize
          return response if bounds.admits?(size)

          condensed(agent, response, size, journal)
        end

        private

        # ONE further ask, never a loop: a child whose summary is ALSO over the
        # ceiling has shown it will not shrink, and asking again would spend
        # another turn to learn the same thing. Note that one ASK is not one
        # provider call -- the child holds tools and its loop re-seeds its
        # iteration count, so the ask is a whole agentic run under the lease
        # this dispatch is still holding.
        #
        # `StandardError` and not the budget alone: a 429, a 529 or a socket
        # reset from the second ask would otherwise escape and destroy an answer
        # the run has already paid for -- on the one-shot path the completion
        # would record a failed child in place of the answer, and on the actor
        # path the raise lands in `@failure`, so no settled note ever reaches
        # the parent's mailbox. {Agent}'s own torn-turn rule is the governing
        # one: work that was paid for stays in the record rather than vanishing
        # with the raise. `Async::Stop` is not a StandardError, so cancellation
        # still flows past this untouched.
        def condensed(agent, response, size, journal)
          summary = agent.ask(request(size))
          reason = undeliverable(summary)
          reason.nil? ? summarized(response, summary, size, journal) : floor(response, size, reason, journal)
        rescue StandardError => e
          floor(response, size, "the summarizing ask itself failed -- #{failure(e)}", journal)
        end

        # The class leads because it stays diagnostic when the message is cut,
        # and the message is cut because it is written by whatever raised and
        # lands in both a model-facing sentence and a journal line.
        def failure(error) = "#{error.class}: #{error.message.to_s[0, MAX_FAILURE_REASON]}"

        # Why this summary cannot be delivered, or nil when it can. Five ways a
        # second ask succeeds and still has nothing to deliver, each of which
        # would otherwise be published UNDER A NOTE PROMISING A SUMMARY: an
        # empty answer, a `:max_tokens` stop, a `:refusal`, a `:malformed` one,
        # and a summary still over the ceiling. Three of them are the reason
        # `stop_reason` is read at all -- a sentence cut off mid-word is
        # precisely the silent truncation this whole path exists to avoid, "I
        # decline." labelled as a summary tells the parent the decline IS the
        # answer it asked for, and a prose tool call so labelled hands the
        # parent an envelope as though it were the child's findings.
        def undeliverable(summary)
          text = summary.text
          return "it answered nothing when asked" if text.empty?
          return "the summary stopped at the model's own token ceiling" if summary.stop_reason == StopReason::MAX_TOKENS
          return "the child declined to summarize it" if summary.stop_reason == StopReason::REFUSAL
          return "the summary was a tool call written as prose" if summary.stop_reason == StopReason::MALFORMED
          return if bounds.admits?(text.bytesize)

          "the summary was #{text.bytesize} #{bounds.unit}, over the ceiling too"
        end

        # The parent is TOLD what it is holding. "Shorter than it might have
        # been" and "the child's whole answer" are different claims, and a
        # reader acting on the second while the first is true is the failure
        # this line exists to prevent.
        #
        # So the ceiling governs the SUMMARY, not the delivery: one number then
        # means one thing in the decision and in the sentence a reader is given,
        # at the cost of the note's own hundred-odd bytes riding on top. A
        # summary at exactly the ceiling therefore delivers slightly over it,
        # and a spawn chain compounds that once per hop -- which is the trade,
        # stated, rather than a measurement that quietly disagrees with itself.
        def summarized(response, summary, size, journal)
          journal << AnswerBounded.new(size:, limit: bounds.limit, outcome: :summarized)
          delivered(response, "[summarized by the subagent itself: its full answer was #{size} " \
                              "#{bounds.unit}, over the ceiling of #{bounds.limit}]\n#{summary.text}")
        end

        # No summary could be delivered, so none is promised. The sentence is
        # {Tool::Bounds::Artifact}'s own refusal: it names the size and the
        # ceiling, says WHICH way the summarizing failed, and offers somewhere
        # to go.
        #
        # `#message`'s SIGNATURE takes no content, which is what keeps the
        # answer's own bytes out. It is not what keeps this sentence bounded:
        # `subject:` is prose {Tool::Bounds} states it deliberately does not
        # police, and `reason` is the one part of it that is not a fixed string.
        # So every reason reaching here is bounded before it arrives -- four
        # are literals, a fifth is a literal plus a byte count, and the sixth
        # is clamped by {#failure}. A floor that blew through the ceiling it enforces would be
        # the exact hazard {Tool::Bounds.ceiling} names: a message that echoes
        # its argument hands the model the bytes a refusal exists to withhold.
        def floor(response, size, reason, journal)
          journal << AnswerBounded.new(size:, limit: bounds.limit, outcome: :floor, reason:)
          delivered(response, bounds.message(subject: "the subagent's answer, which could not be " \
                                                      "summarized (#{reason})", size:, narrower: NARROWER_ASKS))
        end

        # The child's own Response, carrying what the parent is given in place
        # of the text it gave. `Data#with` re-runs {Response}'s own constructor,
        # so the content comes back normalized and deeply frozen.
        def delivered(response, text) = response.with(content: [{ "type" => "text", "text" => text }])

        # The child is told the size, the ceiling and what to keep: a bare
        # "shorten it" invites a summary of the narration rather than of the
        # findings, which is the half the parent spawned it for.
        def request(size)
          "Your answer was #{size} #{bounds.unit}, over this harness's ceiling of #{bounds.limit} for a " \
            "subagent's answer, so it was not delivered to the agent that spawned you. Answer again under " \
            "that ceiling: keep every conclusion and every fact you were asked for, and drop the narration " \
            "of how you reached them. Reply with that shorter answer alone."
        end
      end

      # ONE shared, frozen collaborator, not a fresh one per spawn: it holds
      # only the ceiling, so there is no per-spawn state for one to carry. The
      # default a tool takes, and injectable past it.
      ANSWER = Answer.new

      # One model-facing spawner over several roles, the role named PER CALL
      # from a set fixed where this is built. {Subagent} fixes one role at
      # construction, which is what keeps a capability out of the model's
      # hands; here the set is still fixed there, and the only thing the model
      # chooses is which of them to spend -- so an orchestrator can hand the
      # implementing to a child that writes and the reviewing to one that
      # cannot, without either being a role the model invented.
      #
      # The roles ride the schema as an enum, so the model is shown exactly the
      # set a call may name, and a name outside it comes back as an ordinary
      # is_error result rather than a raise.
      class Choice < Tool
        # The task, and which role is to carry it out. Both are the model's to
        # write; which roles exist is not. {Tasked} comes first so `prompt`
        # still precedes `role` in the rendered schema.
        class Input < Tool::Input
          include Tasked

          field :role, :string, required: true,
                                description: "Which of the roles on offer the subagent takes."
        end

        input_model Input

        # The ceiling a child's answer is held to is the chosen spawner's own,
        # named here because that answer passes through this tool untouched.
        ANSWER_BOUND = Subagent::ANSWER_BOUND

        # @param spawners [Hash{#to_s => Subagent}] one spawner per role on offer
        def initialize(spawners)
          super()
          @spawners = spawners.to_h { |role, spawner| [role.to_s, spawner] }.freeze
        end

        # The model calls this "subagent" whatever roles it offers, so a role
        # added or dropped never changes the tool's name in a rendered schema.
        def name = Subagent::NAME

        def description
          "Spawns a subagent in the role you name (#{roles.join(" or ")}) to carry out `prompt` on " \
            "its own, with that role's tools and its own conversation, and returns only its final " \
            "answer. Use it to fan out a self-contained subtask: the implementing to one role, the " \
            "reviewing to another."
        end

        # @return [Array<String>] the roles on offer, in the order they were given
        def roles = @spawners.keys

        # @param role [#to_s] one of {#roles}
        # @return [Subagent] that role's spawner
        def [](role) = @spawners.fetch(role.to_s)

        def input_schema
          schema = super
          role = schema.fetch("properties").fetch("role").merge("enum" => roles)
          schema.merge("properties" => schema.fetch("properties").merge("role" => role))
        end

        # ASKED of what it holds rather than asserted: every call delegates to
        # one spawner, so this tool is exactly as parallel-safe as the spawners
        # on offer. Restating {Subagent#parallel_safe?}'s `true` would have gone
        # on claiming it for a spawner wired to answer otherwise.
        def parallel_safe? = @spawners.each_value.all?(&:parallel_safe?)

        # Each spawner descends as its own, so every role on offer is capped at
        # the child's ceiling exactly as a lone spawner would be.
        def descend(parent:, escalation:, ceiling:)
          self.class.new(@spawners.transform_values { |spawner| spawner.descend(parent:, escalation:, ceiling:) })
        end

        protected

        def perform(input, invocation)
          return refused(input.role) unless @spawners.key?(input.role)

          @spawners.fetch(input.role).call({ "prompt" => input.prompt }, invocation)
        end

        private

        def refused(role)
          Tool::Result.error("no #{role.inspect} role is on offer here; name one of #{roles.join(", ")}")
        end
      end

      # The isolation a seam was never taught about: the shared-process
      # baseline, so a spawn over an unwired seam resolves its paths exactly
      # where it did before a lease was ever taken.
      #
      # Shared for {NO_OBSERVER}'s equality reason, and NOT frozen for a reason
      # of its own: it owns a worker-id sequence, and a frozen counter cannot
      # count. Sharing one sequence across every unwired seam costs nothing --
      # {Isolation::Null} ignores the id it is handed.
      NO_ISOLATION = Isolation::Leases.new

      # The scope of a seam no board confines.
      module UNSCOPED
        def self.current = Session::Unconfined
      end

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
      # be: `context_factory` and `tool_middleware` are callables, a provider is
      # a live client, and `parent` is a thunk or a Timeline. A new member
      # should say which direction it moves that claim; the current ones move it
      # nowhere new. This bundles collaborators -- it is not a value in the
      # {Event}/{Canonical} sense.
      Seam = Data.define(:provider, :context_factory, :parent, :tool_middleware, :journal, :telemetry, :supervisor,
                         :observer, :askers, :isolation, :escalation, :scope) do
        # Everything after `tool_middleware` defaults to its Null object. The
        # first four stay required, so Data's own missing-keyword error is the
        # loud failure, unwritten.
        #
        # `tool_middleware` has no default and no named Null in lib/: a child's
        # tools run behind the stack this builds -- the guards AND the gate --
        # and a defaulted one is how a production spawn would run ungated while
        # nothing said so. So it is refused unless it can build one at all.
        #
        # It is a builder over the child's {WorkerEnv}, called once per child as
        # that child is built, because a chat's stack reads a board that does
        # not exist yet when this seam does ({CLI::ToolGuard::Spawned}), and
        # because a stack is mutable, so one shared between children would let
        # a `#use` on one reach them all. The environment is what tells a guard
        # where a child leased into a checkout of its own writes.
        #
        # `askers` wants the same treatment and does not yet have it: its
        # default is {NoAskers}, so a chat seam assembled with no askers takes
        # a human question it can never park and never route an answer back
        # to, and says nothing about it. Requiring the keyword was tried and
        # reverted: 45 spec construction frames across 10 files build this
        # Data with the loose members, so it cannot be required until they
        # build it through one factory; {CLI::Wiring::ToolsetBuild} -- the
        # only production constructor -- requires its own.
        #
        # `telemetry` is where a record the live views fold goes -- the tee a
        # chat's approval gate journals to -- and never `journal`, the session
        # file alone. A child that did not answer names the question it left
        # parked consumed there, or the inbox lists it for the rest of the run.
        #
        # `escalation` defaults to `[AskHuman::HUMAN]`: absent a spawn, `parent`
        # IS the run's own chat, so a question asked FROM it need go no further
        # once it is addressed there. A seam a spawn built over
        # ({ChildBuilder#own_chain}) replaces this with whatever `parent`'s OWN
        # further hops are, so a grandchild's relay carries the whole road
        # rather than only its immediate parent's name.
        #
        # `scope` answers `#current`, the session scope children are spawned
        # into; a chat reads its board's. Unscoped by default, since only a
        # board can enter plan scope.
        def initialize(provider:, context_factory:, parent:, tool_middleware:, journal: Channel::Null.instance,
                       telemetry: Channel::Null.instance, supervisor: Supervisor::Null, observer: NO_OBSERVER,
                       askers: NoAskers, isolation: NO_ISOLATION,
                       escalation: [AskHuman::HUMAN].freeze, scope: UNSCOPED)
          Seam.refuse_unbuildable(tool_middleware)

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

        def self.refuse_unbuildable(tool_middleware)
          return if tool_middleware.respond_to?(:call) && !middleware?(tool_middleware)

          raise NotABuilder, "tool_middleware must build a child's tool stack from its WorkerEnv, not be one: " \
                             "got #{tool_middleware.inspect}"
        end

        def self.middleware?(value) = value.is_a?(Middleware::Stack) || value.is_a?(Middleware::Base)

        def self.refuse_unknown(unknown)
          return if unknown.empty?

          raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")}"
        end
        private_class_method :refuse_unknown, :middleware?
      end

      # What a child IS: the union it renders, the Agent over it, the tool
      # stack enforcing its attenuation. Parent-agnostic by construction -- `parent`
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
        #
        # `tools` names what the child was granted, which is what decides
        # whether it may be asked to rebase its own work: only a shell can run
        # git. `asker` and `feed` are what a child that did not answer leaves
        # its record through.
        Child = Data.define(:agent, :registration, :tools, :asker, :feed) do
          # A one-shot child's lifetime IS the dispatch, so the release lands
          # on every exit from it. `timeline` is read AFTER the block: the
          # caller wants the settled head, not the one the child started from.
          def answered
            response = yield(agent, tools)
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
            actor = yield(agent, registration, tools)
          ensure
            registration.deregister unless actor
          end

          # The head a child that did not answer stopped at, written into the
          # record first: its completion cites that head, and an iteration that
          # raised never returned to write it.
          def settled
            feed.catch_up(agent.timeline)
            agent.timeline
          end

          # The question set this child last put to a human, which one that did
          # not answer may have left parked.
          def asked = [asker.last_question&.digest].compact
        end

        # One spawn's own chain: where the child STARTS, how to read its live
        # head, the feed its committed turns reach the session record through,
        # and the whole road a question the child asks travels before it reaches
        # a human -- the parent's own correlation first, then wherever THAT
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
          # the same live head, and the escalation road so the Q names who it
          # was actually put to and {AskHuman} can relay it the rest of the
          # way without ever touching an ancestor's own dispatch.
          def asking_handle
            AskHuman::Parent.new(read: timeline, to: escalation.first, escalation: escalation.drop(1))
          end
        end

        attr_reader :policy, :toolset, :budget

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
        # A child built while a scope confines runs in the scope's environment
        # whatever environment it was handed -- an actor's supervisor leases one
        # of the run's own -- and its session is confined to that scope.
        def build(parent, ceiling:, worker_env: WorkerEnv.default, scope: @seam.scope.current,
                  progress: Progress::Null)
          child = nil
          chain = own_chain(parent, progress) { child.timeline }
          union = child_union(chain.timeline, chain.escalation, ceiling)
          session = Session.new(worker_env: scope.env_over(worker_env), scope:)
          spawned(@seam.askers.enrol(chain.asking_handle, agent: @name), chain, union, session)
            .tap { |built| child = built.agent }
        end

        private

        # One spawn's own chain, built HERE rather than at the Agent, because
        # the asker is enrolled before the Agent exists and needs the feed.
        # Per SPAWN and never memoized on the builder: a fan-out runs sibling
        # spawns concurrently over one of these, so a shared feed would promote
        # one sibling's turns against another's stop digest.
        #
        # Hoisting the base above the attenuation is
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
        def own_chain(parent, progress, &timeline)
          base = @policy.prefix.base_timeline(parent:, store: parent.store)
          Chain.new(base:, timeline:, escalation: Chain.escalation_road(base, parent, @seam.escalation),
                    feed: TurnFeed.new(observer: progress.watching(@seam.observer), base: base.head_digest))
        end

        # A spawn that raises past this point (a Context that will not render,
        # a stack the gate does not close) leaves no lifetime
        # for anyone to hang a `deregister` on, and retention runs from
        # `register` to `deregister` and nothing else -- so this method is the
        # only place that release can live.
        def spawned(enrolled, chain, union, session)
          child = nil
          asker = enrolled.asker
          allowed = granted(@policy.attenuate(union), asker)
          child = Child.new(agent: spawn_agent(chain, granted(union, asker), allowed, session),
                            registration: enrolled.registration, tools: allowed.names, asker:, feed: chain.feed)
        ensure
          # Keyed on the handle rather than `rescue StandardError`, so a
          # CANCELLED spawn releases too: `Async::Stop` is not a StandardError.
          enrolled.registration.deregister unless child
        end

        # The child's own asker, granted ON TOP of the attenuated set rather
        # than folded into the union it attenuates from: no role in the catalog
        # names `ask_human` in its `only`-set, so a set that went through
        # {Tool::SpawnPolicy#attenuate} would have dropped it.
        #
        # The grant is a default with a CONDITION that must survive a future
        # edit: the ROLE governs it, through {Tool::SpawnPolicy}'s `unattended`
        # -- an arm that answers with nobody minding it holds no tool that can
        # block on a human, and `only:` cannot say so from inside a set this
        # grant is deliberately outside of.
        #
        # REPLACING rather than appending, and the strip is UNCONDITIONAL where
        # the grant is not. A union that already holds an `ask_human` holds the
        # PARENT's, whose questions would be attributed to the parent's chain
        # and whose promise the parent's {AskHuman::Outstanding} holds. So an
        # early return for the unattended case would leave the PARENT's asker
        # standing in the dispatch union -- reachable, and under `handler_union`
        # rendered, to the very child the role just muted.
        def granted(set, asker)
          own = @policy.unattended ? [] : [asker]
          Toolset.new(set.reject { |tool| tool.name == asker.name } + own)
        end

        # Every spawner in the injected union is replaced by a descended copy:
        # handing the SAME instances down would let a nested spawn keep its
        # constructing ceiling, and recursion would never terminate via the cap.
        # The copy's schema bytes are identical, so the rendered tools block --
        # and with it the cache prefix -- is unchanged.
        #
        # Keyed on the `#descend` DUCK rather than on the class, which is safe
        # only because this union is assembled below the trust boundary: a run's
        # own wiring decides what is in it, never the model, so a tool answering
        # the duck is one lain put there.
        def child_union(parent_handle, escalation, ceiling)
          Toolset.new(@toolset.map do |tool|
            tool.respond_to?(:descend) ? tool.descend(parent: parent_handle, escalation:, ceiling:) : tool
          end)
        end

        # A fresh {Session} per spawn -- never {Session::Null} -- so a
        # write-capable child can satisfy EditFile's read-before-write contract
        # against its OWN read-set. Built here, not memoized: a builder is
        # reused across sibling spawns, so a memoized Session would leak one
        # sibling's reads into the next. This builder is never handed the
        # parent's Session, so the child's read-set starts empty by
        # construction.
        #
        # Its tool phase is whatever stack the seam's builder makes for THIS
        # child: a chat's is the parent's own stack over the parent's board, gate
        # included, so a child's read is masked, parked and released, and its
        # gated call asked about, exactly as the parent's.
        #
        # The interpreter is a bare {Effect::Handler::Live}: the runner resolves
        # each call against the RENDERED toolset -- the attenuated set under
        # `schema`, the descended union under `handler_union` -- so a permitted
        # nested subagent runs at its decremented ceiling.
        #
        # The child Agent's OWN journal discards, deliberately, while the seam's
        # records around it reach the session file. What an Agent journals is
        # its `turn_usage` and `tool_cancelled`, and a child's in the parent's
        # file would read as the parent's: salvage would pair it with the
        # parent's in-flight `request_sent`, cache-waste would count it, and the
        # ledger would price it as the parent's spend.
        def spawn_agent(chain, union, allowed, session)
          Agent.new(
            provider: @seam.provider, context: child_context,
            toolset: @policy.posture.rendered_toolset(union:, allowed:), handler: Effect::Handler::Live.new,
            timeline: chain.base, turn_middleware: recorded_turns(chain),
            model_middleware: child_budget, tool_middleware: child_stack(session.worker_env, allowed),
            session:, budget: @budget, journal: Channel::Null.instance
          )
        end

        # The child's model phase, and its one member: a prompt the provider
        # refuses WHOLE is the one failure a child cannot report as an answer,
        # and without this the spawner was handed the server's own error body,
        # naming neither the child nor anything the spawner could do about it.
        #
        # Its record goes to the seam's DURABLE journal and never to the
        # telemetry tee. That is the opposite of the rule the rest of this seam
        # follows, and for the reason that rule exists: a live view folds what
        # it is fanned, and this count is the CHILD's -- measured against the
        # child's window on a chain the parent never rendered -- so folding it
        # would move the parent's HUD onto a context the human cannot act on.
        # The record names the spawn so a reader can tell whose it is wherever
        # it is read back.
        def child_budget
          voice = Middleware::RequestBudget::Child.new(name: @name)
          Middleware::Stack.new([Middleware::RequestBudget.new(journal: @seam.journal, voice:)])
        end

        # `schema` renders the attenuated set, so the stack as built suffices;
        # `handler_union` renders the shared union, so {Middleware::RefuseUnpermitted}
        # enforces the `only`-set the model can see but must not use.
        #
        # It goes just outside the path refusal, never around the whole stack
        # and never inside the gate: the guards still see every call first, and
        # a call the child was never attenuated to is refused outright, not
        # parked for a human who would then watch it be refused anyway. Into a
        # COPY, because a builder may hand every child the one stack it holds.
        #
        # Whatever the builder returns is held to {Middleware::Gate.closes!}
        # first: the builder is the only place a child's gate comes from, so a
        # stack it does not end in the gate is refused here, as the child is
        # built and before any of its tools can run.
        def child_stack(worker_env, allowed)
          stack = Middleware::Gate.closes!(Middleware::Stack.new(@seam.tool_middleware.call(worker_env).to_a))
          return stack unless @policy.posture.refuses_over_union?

          stack.insert_before(Middleware::Sensitivity,
                              Middleware::RefuseUnpermitted.new(allowed: allowed.names, journal: @seam.journal))
        end

        # The child's turns, into the session record as each is committed,
        # before any tool it called runs: a child's `ask_human` question and a
        # grandchild's :spawn are written DURING that tool round and cite the
        # turn that opened it, and an iteration that parks on a human never
        # returns to catch up afterwards. The timeline rides a thunk because the
        # turn env carries the PRE-step snapshot, and is late-bound because the
        # middleware must exist before the Agent that runs it.
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
      end
    end
  end
end
