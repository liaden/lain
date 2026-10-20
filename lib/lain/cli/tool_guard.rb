# frozen_string_literal: true

module Lain
  module CLI
    # The one builder of an agent's tool stack -- a chat's, each of its
    # children's, and a run's with no chat: the guards on what a tool may write,
    # read and list, then the gate that decides whether a call runs at all.
    #
    # {Middleware::ConfineToScope} goes first: while the board's scope confines,
    # a write or a command aimed outside its directory is refused before any
    # other guard, or any human, is asked about it. It reads the board's scope
    # per call, so a flip reaches a stack built before it, and every session
    # judged through the board is confined, whichever way it was spawned.
    #
    # {Middleware::RefuseSecretWrites} sits in the TOOL phase so a
    # credential-shaped memory_write is withheld before it ever reaches the
    # recorder: a memory, once indexed, replays into every future context, and
    # there is no un-indexing it. {Middleware::RedactSecretReads} is its mirror
    # on the read side -- a region masked out of a `read_file`, `grep` or
    # `ast_search` result never reaches an Event, a digest or the prompt-cache
    # prefix. It and {Middleware::WithholdSecretPaths} both see `grep` and
    # `ast_search`, and it runs outside that filter so it scans only the rows
    # the filter kept.
    #
    # {Middleware::GuardTestLayout} holds the writing tools against the
    # project's test layout, and is disjoint from all three.
    #
    # {Middleware::WithholdAutomaticOutput} sits before the gate's two layers,
    # because what it reads is the gate's decision: a `bash` result is scanned
    # only when no human approved the call. {Middleware::RememberedDenials}
    # sits after it, ahead of the gate's two layers, refusing a call on a path
    # a human already denied its requester before the gate can park it again.
    #
    # Then the gate's two layers: {Middleware::Sensitivity} refuses a path no
    # approval can lift, and {Middleware::Gate} asks about what a human may
    # still allow. The guards run first, so a secret write is refused before a
    # human is ever asked about it, and the gate runs LAST: it approves the
    # tool the runner resolved and the input it was shown, so a layer after it
    # could rewrite what was approved.
    #
    # Ahead of all of them runs what a user's or a project's config.rb
    # registers for the tool phase ({.configured}): every guard then judges
    # whatever that middleware passes on, and it sees a result only after the
    # guards have masked it.
    #
    # A child runs the same stack: the spawn seam carries a builder over it
    # ({Spawned}), so every child is guarded and gated over its parent's board
    # ({.child_stack}). A run with no chat to borrow a board from builds its own
    # through {.detached}. This module is the one place an agent's tool stack is
    # assembled.
    module ToolGuard
      # Everything the stack is built over, as ONE value: the run's one region
      # ledger, its approval queue (nil when nobody attends), its path policy,
      # its test layout run, the gate's policy, the policy a worker's gate asks
      # (`policy_for`, `worker_env -> #rule`), the sentence a refused call is
      # reported in (`%<name>s` standing for the tool), and the commands barred
      # from automatic approval. A {Switchboard} holds one
      # ({Switchboard#guard_inputs}); a run with no chat builds its own.
      #
      # `policy_for` has no default: a board that forgot it would judge every
      # leased child by its parent's policy, in silence. `scope` answers
      # `#current`, the session scope the board is in; a run that can never
      # enter plan scope confines nothing, which is its default. `middleware`
      # is what the chat's config.rb files registered; a run with no chat
      # reads no config, which is its default. `denied_tools` are the tools its
      # config refuses outright, which the gate refuses whatever their tier.
      Inputs = Data.define(:ledger, :approvals, :sensitivity, :test_layout, :policy, :policy_for, :denial, :bar,
                           :scope, :middleware, :child_env, :denied_tools) do
        def initialize(scope: UNSCOPED, middleware: Config::Middleware.empty,
                       child_env: Exec::ChildEnv::DEFAULT, denied_tools: Set[].freeze, **)
          super
        end
      end

      # The scope of a run with no board that can enter plan.
      module UNSCOPED
        def self.current = Session::Unconfined
      end

      Held = Data.define(:current)

      # The board's scope, read through the thunk a spawn seam holds, so a
      # child built before the board existed still reads the scope in force.
      BoardScope = Data.define(:board) do
        def current = board.call.guard_inputs.scope.current
      end

      # The gate policy a child is asked through: the board's own, handed a
      # context that names the child, so a park says which of a fleet is asking
      # while the verdict is still the one policy the parent asks. The name
      # rides the context ({Approval::PolicySwitch::Requested}) rather than a
      # new parameter, because `rule(effect, context)` is what every policy on
      # this seam already answers. What it wraps is adapted the way the Gate
      # adapts what it is handed, since the Gate only ever sees this wrapper.
      Asking = Data.define(:policy, :requester, :task) do
        def initialize(policy:, requester:, task: nil)
          super(policy: Middleware::Gate::Callable.of(policy), requester:, task:)
        end

        def call(effect, context) = rule(effect, context).allow?

        # What the Gate asks, so a child is told why a refusal was made in the
        # same words its parent is.
        def rule(effect, context) = policy.rule(effect, requested(context))

        private

        def requested(context) = Approval::PolicySwitch::Requested.new(context, requester, task:)
      end

      # What a chat's spawn seam carries as its tool middleware: a builder over
      # the board, for the children of whoever `requester` names.
      #
      # The board arrives as a THUNK, because the seam is built while the toolset
      # is, and the board requires that toolset. It is read when a child is
      # built, by which time the board exists and cannot change -- so the
      # stack a child gets holds the board's own objects, not delegators over
      # it, and a board still nil then raises rather than gating a child over
      # nothing.
      #
      # A value rather than a lambda so the name can be rebound: a spawn that
      # announces a role copies the run's one seam with a different
      # `requester` and every other member shared.
      #
      # A child whose lease cut a checkout is held inside it ({.child_stack}):
      # outside plan the board's scope confines nothing.
      Spawned = Data.define(:chronicle, :board, :requester) do
        # @param worker_env [WorkerEnv] the environment the child runs in
        # @param task [String, nil] what the child was spawned to do, asked about beside its name
        # @return [Middleware::Stack] a fresh one per child
        def call(worker_env, task: nil) = ToolGuard.child_stack(chronicle, board.call, worker_env, requester:, task:)

        # Read off the board as a child is built, never before.
        def guard_inputs = board.call.guard_inputs

        # @return [NeverParking]
        def never_parking = NeverParking.new(guard: self, requester: Approval::Judge::ROLE.to_s)
      end

      # What {.detached} answers: a builder over the inputs a run with no chat
      # built for itself, once. A child whose lease cut a checkout is held
      # inside it ({.leased}).
      #
      # It answers `with(requester:)` as {Spawned} does, so a role spawn names
      # its children to the gate and the journal whichever builder its seam
      # holds. Until then its gate asks as the run's own agent. No current
      # caller spawns a role over it except through {#never_parking}, whose
      # copy names the child's role the same way.
      Detached = Data.define(:chronicle, :guard_inputs, :requester) do
        def initialize(chronicle:, guard_inputs:, requester: nil) = super

        # @param worker_env [WorkerEnv] the environment the child runs in
        # @param task [String, nil] what the child was spawned to do, asked about beside its name
        # @return [Middleware::Stack] a fresh one per child, over the one board
        def call(worker_env, task: nil)
          return ToolGuard.leased(chronicle, guard_inputs, worker_env, requester:, task:) if worker_env.checkout

          ToolGuard.working(chronicle, guard_inputs, worker_env,
                            ToolGuard.named(guard_inputs.policy_for.call(worker_env), requester, task:), requester:)
        end

        # @return [NeverParking]
        def never_parking = NeverParking.new(guard: self, requester: Approval::Judge::ROLE.to_s)
      end

      # A seam's builder as an approval judge spawns through it. The judge waits
      # on its child's answer with the judged call still parked, so a child that
      # parked in turn would wait on the very judgement it was spawned to serve.
      # Every approval such a child needs refuses instead, in words: its gate
      # asks the one {Unasked} rung whatever the board would have allowed, and
      # a masked region stays masked. The ledger, the layout and the bar are
      # the guard's own, and so is the path policy, confined as every child's is.
      #
      # This is a property of the spawn site, not of the role: a docent is
      # unattended too, and its read still parks, because nothing that could
      # answer that park is waiting on the docent.
      NeverParking = Data.define(:guard, :requester) do
        # @param worker_env [WorkerEnv] the environment the child runs in
        # @return [Middleware::Stack] a fresh one per child
        def call(worker_env, **) = ToolGuard.working(chronicle, refused, worker_env, asking, requester:)

        # The child's own role names the refusal it records: the seam's requester
        # is whoever spawned the child, and a refusal is not that spawner's doing.
        def asking = Asking.new(policy: refused.policy, requester:)

        def refused = ToolGuard.refusing(chronicle, guard.guard_inputs)

        def chronicle = guard.chronicle

        def never_parking = self
      end

      # What {.stack} reads off a chronicle, for a run that holds only a journal.
      Journaled = Data.define(:journal) do
        def instrumentation = Lain::Agent::Instrumentation.new(journal:)
      end

      # The approval queue out of chat, which releases nothing: nobody is at a
      # surface to answer, so a masked region stays masked.
      # {Middleware::RedactSecretReads::Unqueued} answers the other way on
      # purpose -- that is a chat's unattended fail-open, kept pending its own
      # measurement, and a run that never had a human in its loop has no
      # approval for it to stand in for.
      module Unreleased
        # The messages the read guard asks of a settled answer.
        module Verdict
          def self.approved? = false
          def self.timed_out? = false
        end

        # `outstanding:` is a KEYWORD, so the name is the duck and cannot take
        # the unused-argument underscore.
        def self.adjudicate(_effect, _context, outstanding: nil) = Verdict # rubocop:disable Lint/UnusedMethodArgument

        # Nobody was asked, so nobody denied anything.
        def self.denied(**) = nil
        def self.denied_call(**) = nil
      end

      # The whole ladder a judge's child's gate asks: one rung, refusing.
      # {Switchboard::Unattended}'s shape and name, so a reader tallying
      # refusals by rung counts both as "nobody could be asked", but its own
      # reason: the chat has a human, and the record must not say otherwise.
      class Unasked
        NAME = Switchboard::Unattended::NAME
        BECAUSE = "this child cannot ask a human: it was spawned by an approval judge that is waiting on its answer"

        def initialize = freeze

        def name = NAME

        def call(_effect, _context) = Approval::Escalation::Ruling.deny(rung: NAME, because: BECAUSE)
      end

      # The gate policy of a leased run with no chat: what only a tool's tier
      # gates runs, as {Middleware::Gate::ApproveAll} would run it, and what
      # the lease's path policy gates is refused. The gate cannot say which
      # axis gated a call, so this asks the path policy the same question.
      # Final, because no human is attached to lift it.
      #
      # A command whose paths cannot be read is refused too: the lease's hold
      # checks only the paths a command names, and a loop, an expansion or an
      # inline script names none, so nothing else stands between it and a
      # write outside the lease.
      class LeasedPolicy
        RUNG = "lease"
        ALLOW = Middleware::Gate::ApproveAll.new.freeze
        LEASED_READ = "this run is leased to %<lease>s and no human is attached to approve a call outside it; " \
                      "work inside %<lease>s"
        LEASED_OPAQUE = "this run is leased to %<lease>s and no human is attached, so a command whose paths " \
                        "cannot be read is refused (a loop, $(...), cd then ;, sh -c, ruby -e, xargs); write a " \
                        "script in %<lease>s and run it, or send the steps as separate calls"

        # @param sensitivity [#gates?] the path policy the run's gate asks
        # @param lease [String] the checkout the run was leased
        # @param allow [#rule] who rules a call inside the lease; approves it by default
        # @param home [String, nil] what a `~` in a command names; with none, such a command is unreadable
        def initialize(sensitivity:, lease:, allow: ALLOW, home: nil)
          @sensitivity = sensitivity
          @lease = lease
          @allow = allow
          @home = home
          freeze
        end

        def call(effect, context) = rule(effect, context).allow?

        # @return [Approval::Escalation::Ruling]
        def rule(effect, context)
          wording = refusal(effect, context)
          return @allow.rule(effect, context) unless wording

          Approval::Escalation::Ruling.deny(rung: RUNG, because: format(wording, lease: @lease), final: true)
        end

        private

        def refusal(effect, context)
          return LEASED_READ if outside?(effect, context)

          LEASED_OPAQUE if unreadable?(effect, context)
        end

        def unreadable?(effect, context)
          return false unless effect.tool_call? && effect.name == "bash"

          Middleware::ParsedCommand.named_in(effect, context, home: @home).opaque?
        end

        def outside?(effect, context)
          @sensitivity.gates?(effect, cwd: ::Lain::Session.cwd_of(context),
                                      within: ::Lain::Sensitivity::Policy.base_of(context))
        end
      end

      # What a judge's child is told when its gate refuses, on {Switchboard#denial}'s
      # rule: say that nobody said no and that retrying cannot help. What to do
      # instead is to report the gap, never to work around it: a judge settling
      # on evidence it never saw is the approval deny-when-unsure exists to stop.
      UNPARKED = "tool %<name>s was refused: this child cannot ask a human, so nothing it needs approved can " \
                 "be approved. This is not somebody answering no -- retrying will fail the same way every time. " \
                 "Whatever this call would have shown you is missing evidence: report it as missing, and do not " \
                 "reach any conclusion as though you had seen it."

      module_function

      # @param chronicle [CLI::Chronicle] resolves where a refusal is recorded
      # @param board [#guard_inputs] the run's {CLI::Switchboard}, whose one
      #   {Inputs} holds the run's ONE region ledger and approval queue --
      #   passed whole because "one ledger per run" is the board's invariant,
      #   not this module's.
      # @return [Middleware::Stack] the tool-phase stack, for the instrumentation
      def stack(chronicle, board)
        inputs = board.guard_inputs
        layered(chronicle, inputs, [inputs.test_layout.root], inputs.policy)
      end

      # A child's stack: the parent's, layer for layer, except that a child
      # leased into a checkout of its own writes and runs commands THERE. Its
      # layout guard holds that checkout's root beside the project's, and its
      # gate asks the policy the board answers for its environment -- whose
      # rungs read a command's words in that checkout -- on behalf of the child
      # `requester` names, as its read guard asks a release. The ledger and
      # listing filter stay the board's one, and the path policy is the board's
      # confined to the child's scope ({.working}). A child whose environment
      # names a checkout is held inside it, as plan scope holds one inside the
      # spike; one that names none is held nowhere.
      #
      # @param chronicle [CLI::Chronicle] as on {.stack}
      # @param board [CLI::Switchboard] as on {.stack}
      # @param worker_env [WorkerEnv] the environment the child runs in
      # @param requester [Requester, String] who a human is told is asking
      # @param task [String, nil] what the child was spawned to do
      # @return [Middleware::Stack]
      def child_stack(chronicle, board, worker_env, requester:, task: nil)
        inputs = board.guard_inputs
        asking = Asking.new(policy: inputs.policy_for.call(worker_env), requester:, task:)
        working(chronicle, inputs, worker_env, asking,
                requester:, held: held_for(worker_env, home: inputs.sensitivity.home))
      end

      # @param worker_env [WorkerEnv] the child's
      # @param home [String, nil] what a `~` in a command names
      # @return [Array<Middleware::ConfineToScope>] the hold on its checkout,
      #   or none for an environment whose lease cut no checkout
      def held_for(worker_env, home:) = worker_env.checkout ? [held_in(worker_env, home:)] : []

      # Read once, as the child is built: the checkout is the lease's, and a
      # lease never moves.
      #
      # @param worker_env [WorkerEnv] the leased child's, naming its checkout
      # @param home [String, nil] what a `~` in a command names
      # @return [Middleware::ConfineToScope]
      def held_in(worker_env, home:)
        scope = Session::Confined.new(worker_env:, reminder: "")
        Middleware::ConfineToScope.new(scope: Held.new(current: scope), wording: Middleware::ConfineToScope::LEASE,
                                       reach: Middleware::ConfineToScope::Reach.new(home:))
      end

      # A worker's stack, over the inputs it is guarded by, the checkout its
      # environment names if its lease cut one, the policy its gate asks, and
      # the child a release is asked for -- nil for a worker nobody named.
      #
      # Its path policy is confined to the project, its related directories
      # and the worker's own tree, so a read anywhere else asks first. The main
      # agent's stack is built by {.stack} and reads where it likes.
      def working(chronicle, inputs, worker_env, policy = inputs.policy, requester: nil, held: [])
        layered(chronicle, confined(inputs, worker_env), inputs.test_layout.roots_for(worker_env), policy,
                requester:, held:)
      end

      # A child of a run with no chat, leased a checkout: held inside it as a
      # chat's leased child is, and its gate refuses what that hold leaves to
      # a human, because nobody is attached to answer ({LeasedPolicy}).
      #
      # @return [Middleware::Stack]
      def leased(chronicle, inputs, worker_env, requester: nil, task: nil)
        held = confined(inputs, worker_env)
        policy = LeasedPolicy.new(sensitivity: held.sensitivity, lease: worker_env.checkout,
                                  allow: inputs.policy_for.call(worker_env), home: inputs.sensitivity.home)
        layered(chronicle, held, inputs.test_layout.roots_for(worker_env), named(policy, requester, task:),
                requester:, held: held_for(worker_env, home: inputs.sensitivity.home))
      end

      # A gate policy asked in `requester`'s name, or as it is when nobody is
      # named: {Asking} refuses a nil name, and the approval queue reads a bare
      # context as the run's own agent ({Approval::Queue::REQUESTER}).
      #
      # @param policy [#rule]
      # @param requester [Requester, String, nil]
      # @param task [String, nil] what the child was spawned to do
      # @return [#rule]
      def named(policy, requester, task: nil) = requester ? Asking.new(policy:, requester:, task:) : policy

      def confined(inputs, worker_env)
        roots = worker_env.checkout ? [worker_env.checkout, *worker_env.read_roots] : [worker_env.cwd]
        inputs.with(sensitivity: inputs.sensitivity.confined(roots:))
      end

      # The configured members, then the eight guards over one set of inputs,
      # the layout held at `roots`, and the gate's two layers asking `policy`
      # -- checked closed as it is built, the one check a child's stack from
      # any builder is also held to.
      def layered(chronicle, inputs, roots, policy, requester: nil, held: [])
        journal = chronicle.instrumentation.journal
        requester &&= Requester.of(requester)
        Middleware::Gate.closes!(
          Middleware::Stack.new([*configured_then_parsed(inputs),
                                 Middleware::ConfineToScope.new(scope: inputs.scope), *held,
                                 Middleware::RefuseSecretWrites.new(**kwargs(chronicle)),
                                 Middleware::RedactSecretReads.new(**read_kwargs(chronicle, inputs), requester:),
                                 Middleware::WithholdSecretPaths.new(filter: path_filter(inputs)),
                                 Middleware::GuardTestLayout.new(run: inputs.test_layout, roots:, journal:),
                                 Middleware::WithholdAutomaticOutput.new(bar: inputs.bar, journal:),
                                 remembered(inputs, requester, journal), *gating(inputs, policy, journal, requester)])
        )
      end

      # Over the board's one queue, so a deny given through any stack is held
      # by every stack asking for the same requester.
      def remembered(inputs, requester, journal)
        Middleware::RememberedDenials.new(queue: inputs.approvals || Middleware::RememberedDenials::Unattended,
                                          sensitivity: inputs.sensitivity, denial: inputs.denial, journal:,
                                          requester:)
      end

      def gating(inputs, policy, journal, requester)
        [Middleware::Sensitivity.new(sensitivity: inputs.sensitivity, journal:, requester:),
         Middleware::Gate.new(policy:, sensitivity: inputs.sensitivity, denial: inputs.denial,
                              denied_tools: inputs.denied_tools, journal:, requester:)]
      end

      # The parse follows the configured members, which may rewrite the command, so every
      # guard below reads the text that will run.
      def configured_then_parsed(inputs)
        [*configured(inputs), Middleware::ParsedCommand.new(home: inputs.sensitivity.home)]
      end

      # Fresh instances on every call, so no two stacks share one.
      #
      # @param inputs [Inputs]
      # @return [Array] the tool members the run's config registered, in written order
      def configured(inputs) = inputs.middleware.members(:tool)

      # The guard for a run with no chat, as the builder a spawn seam carries.
      # The board is built ONCE, here, so every child the run spawns releases
      # into one ledger.
      #
      # Its gate APPROVES, deliberately against {Middleware::Gate}'s own
      # fail-closed default: a run with no chat has no surface for a question
      # to reach, so the roles it spawns unattended would park or refuse
      # forever -- and none of them holds a gated tool, which
      # `subagent_gate_spec` audits from the spawn sites. A child leased a
      # checkout is the exception, held to it by {LeasedPolicy}: a bench arm
      # holds the writing tools.
      #
      # Its path policy is the Null confined to `roots`, and the gate reads the
      # same one: a listing filtered through a policy the gate never consults
      # would hide a path the child can still read by name. The read guard
      # needs no path policy to mask a credential region, which is the half
      # this run can enforce. It reads no `tests` table either: with no chat
      # no project config is read, so a leased child's writes are held by its
      # lease rather than by a layout.
      #
      # @param journal [#<<] where a refusal or a mask is recorded
      # @param roots [Array<String>] absolute; the run's own trees, in scope
      #   for every child wherever it stands
      # @param policy_for [#call, nil] `worker_env -> #rule`, who rules a call a child may make;
      #   approves every one when nil
      # @return [Detached] `worker_env -> stack`, a fresh one per call, every
      #   one over the same board
      def detached(journal:, roots: [], policy_for: nil)
        approve_all = Middleware::Gate::ApproveAll.new
        policy_for ||= ->(_worker_env) { approve_all }
        inputs = Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: Unreleased,
                            sensitivity: Lain::Sensitivity::Policy::Null.instance.confined(roots:),
                            test_layout: Middleware::GuardTestLayout::Run.undeclared,
                            policy: approve_all, policy_for:,
                            denial: Middleware::Gate::DENIAL, bar: Middleware::WithholdAutomaticOutput::Bar.new)
        Detached.new(chronicle: Journaled.new(journal:), guard_inputs: inputs)
      end

      # `inputs` with every approval refused: the gate policy is a ladder of the
      # one refusing rung, journaled where the chronicle records every other
      # ruling, and nothing releases a masked region.
      #
      # @param chronicle [CLI::Chronicle] as on {.stack}
      # @param inputs [Inputs] the guard's own
      # @return [Inputs]
      def refusing(chronicle, inputs)
        ladder = Approval::Escalation.new([Unasked.new], journal: chronicle.instrumentation.journal,
                                                         label: Unasked::NAME)
        inputs.with(approvals: Unreleased, policy: ladder, policy_for: ->(_worker_env) { ladder }, denial: UNPARKED)
      end

      # The third guard covers the LISTING tools, which the other two do not
      # touch: dropping a row out of an enumeration is a different result shape
      # from masking a region inside one file's content.
      #
      # The filter is the BOARD's own, never one built here. A filter over a
      # freshly built classifier would judge a DIFFERENT set of paths than the
      # gate, so a run would enumerate paths its own gate refuses to read; the
      # discipline that keeps that out is that `Filter.new` happens in exactly
      # one place in `lib/`, inside {Sensitivity::Policy}, and every reader
      # takes the filter that came with the gate.
      #
      # It SNAPSHOTS the filter, as the gate's two layers snapshot the policy
      # beside it, so that agreement rests on the slot being construction-fixed:
      # {Switchboard} exposes no writer for it and does not re-bind it. Should
      # it ever become re-bindable, all three have to become late together.
      def path_filter(inputs) = inputs.sensitivity.filter

      # An unattended run wires NO queue ({Switchboard#approvals} is nil), and
      # the stand-in is named HERE rather than defaulted inside the middleware:
      # a `queue:` with a default is how a forgotten injection becomes silent
      # approval. The stand-in approves, which
      # {Middleware::RedactSecretReads::Unqueued} records as the run's one
      # fail-open.
      def read_kwargs(chronicle, inputs)
        { ledger: inputs.ledger,
          queue: inputs.approvals || Middleware::RedactSecretReads::Unqueued.instance,
          journal: chronicle.instrumentation.journal, related: inputs.sensitivity,
          child_env: inputs.child_env }
      end

      # The journal is READ off the chronicle's {Agent::Instrumentation}, whose
      # value carries a Channel::Null under --no-journal: an explicit
      # `journal: nil` crashes on `<<` at refusal time, the worst possible
      # moment.
      #
      # The `oracle:` arm is a CONTENTLESSNESS FLOOR, not a second secret
      # detector ({Oracle::MemorySave}): it declines an empty save under its
      # own name rather than a PATTERNS one, and abstains entirely for a
      # guarded tool carrying no `body`, which is what keeps improvement_write
      # from being refused wholesale.
      def kwargs(chronicle)
        { oracle: Oracle::MemorySave::Gate.new, journal: chronicle.instrumentation.journal }
      end
    end
  end
end
