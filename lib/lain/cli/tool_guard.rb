# frozen_string_literal: true

module Lain
  module CLI
    # The one builder of an agent's tool stack -- a chat's, each of its
    # children's, and a run's with no chat: the guards on what a tool may write,
    # read and list, then the gate that decides whether a call runs at all.
    #
    # {Middleware::RefuseSecretWrites} sits in the TOOL phase so a
    # credential-shaped memory_write is withheld before it ever reaches the
    # recorder: a memory, once indexed, replays into every future context, and
    # there is no un-indexing it. {Middleware::RedactSecretReads} is its mirror
    # on the read side -- a region masked out of a `read_file` result never
    # reaches an Event, a digest or the prompt-cache prefix. The two guard
    # disjoint tools, so their order carries no constraint to get wrong.
    #
    # {Middleware::GuardTestLayout} holds the writing tools against the
    # project's test layout, and is disjoint from all three.
    #
    # {Middleware::WithholdAutomaticOutput} sits directly before the gate's two
    # layers, because what it reads is the gate's decision: a `bash` result is
    # scanned only when no human approved the call.
    #
    # Then the gate's two layers: {Middleware::Sensitivity} refuses a path no
    # approval can lift, and {Middleware::Gate} asks about what a human may
    # still allow. The guards run first, so a secret write is refused before a
    # human is ever asked about it, and the gate runs LAST: it approves the
    # tool the runner resolved and the input it was shown, so a layer after it
    # could rewrite what was approved.
    #
    # A child runs the same stack: the spawn seam carries a builder over it
    # ({Spawned}), so every child is guarded and gated over its parent's board
    # ({.child_stack}). A run with no chat to borrow a board from builds its own
    # through {.detached}. This module is the one place an agent's tool stack is
    # assembled.
    module ToolGuard
      # Everything the stack is built over, as ONE value: the run's one region
      # ledger, its approval queue (nil when nobody attends), its path policy,
      # its test layout run, the gate's policy, the sentence a refused call
      # is reported in (`%<name>s` standing for the tool), and the commands
      # barred from automatic approval. A {Switchboard} holds one
      # ({Switchboard#guard_inputs}); a run with no chat builds its own.
      Inputs = Data.define(:ledger, :approvals, :sensitivity, :test_layout, :policy, :denial, :bar)

      # The gate policy a child is asked through: the board's own, handed a
      # context that names the child, so a park says which of a fleet is asking
      # while the verdict is still the one policy the parent asks. The name
      # rides the context ({Approval::PolicySwitch::Requested}) rather than a
      # new parameter, because `rule(effect, context)` is what every policy on
      # this seam already answers. What it wraps is adapted the way the Gate
      # adapts what it is handed, since the Gate only ever sees this wrapper.
      Asking = Data.define(:policy, :requester) do
        def initialize(policy:, requester:)
          super(policy: Middleware::Gate::Callable.of(policy), requester:)
        end

        def call(effect, context) = rule(effect, context).allow?

        # What the Gate asks, so a child is told why a refusal was made in the
        # same words its parent is.
        def rule(effect, context) = policy.rule(effect, requested(context))

        private

        def requested(context) = Approval::PolicySwitch::Requested.new(context, requester)
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
      Spawned = Data.define(:chronicle, :board, :requester) do
        # @param worker_env [WorkerEnv] the environment the child runs in
        # @return [Middleware::Stack] a fresh one per child
        def call(worker_env) = ToolGuard.child_stack(chronicle, board.call, worker_env, requester:)
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
        # The one message the read guard asks of a settled answer.
        module Verdict
          def self.approved? = false
        end

        # `outstanding:` is a KEYWORD, so the name is the duck and cannot take
        # the unused-argument underscore.
        def self.adjudicate(_effect, _context, outstanding: nil) = Verdict # rubocop:disable Lint/UnusedMethodArgument
      end

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
      # leased into a checkout of its own writes THERE, so its layout guard
      # holds that checkout's root beside the project's, and its gate asks the
      # board's policy on behalf of the child `requester` names.
      #
      # @param chronicle [CLI::Chronicle] as on {.stack}
      # @param board [CLI::Switchboard] as on {.stack}
      # @param worker_env [WorkerEnv] the environment the child runs in
      # @param requester [String] who a human is told is asking
      # @return [Middleware::Stack]
      def child_stack(chronicle, board, worker_env, requester:)
        inputs = board.guard_inputs
        working(chronicle, inputs, worker_env, Asking.new(policy: inputs.policy, requester:))
      end

      # A worker's stack, over the inputs it is guarded by, the checkout its
      # environment names if its lease cut one, and the policy its gate asks.
      def working(chronicle, inputs, worker_env, policy = inputs.policy)
        layered(chronicle, inputs, inputs.test_layout.roots_for(worker_env), policy)
      end

      # The five guards over one set of inputs, the layout held at `roots`, and
      # the gate's two layers asking `policy` -- checked closed as it is built,
      # the one check a child's stack from any builder is also held to.
      def layered(chronicle, inputs, roots, policy)
        journal = chronicle.instrumentation.journal
        Middleware::Gate.closes!(
          Middleware::Stack.new([Middleware::RefuseSecretWrites.new(**kwargs(chronicle)),
                                 Middleware::RedactSecretReads.new(**read_kwargs(chronicle, inputs)),
                                 Middleware::WithholdSecretPaths.new(filter: path_filter(inputs)),
                                 Middleware::GuardTestLayout.new(run: inputs.test_layout, roots:, journal:),
                                 Middleware::WithholdAutomaticOutput.new(bar: inputs.bar, journal:),
                                 Middleware::Sensitivity.new(sensitivity: inputs.sensitivity, journal:),
                                 Middleware::Gate.new(policy:, sensitivity: inputs.sensitivity,
                                                      denial: inputs.denial)])
        )
      end

      # The guard for a run with no chat, as the thunk a spawn seam carries.
      # The board is built ONCE, here, so every child the run spawns releases
      # into one ledger.
      #
      # Its gate APPROVES, deliberately against {Middleware::Gate}'s own
      # fail-closed default: a run with no chat has no surface for a question
      # to reach, so the roles it spawns unattended would park or refuse
      # forever -- and none of them holds a gated tool, which
      # `subagent_gate_spec` audits from the spawn sites.
      #
      # Its path policy is the Null, and the gate reads the same one: a listing
      # filtered through a policy the gate never consults would hide a path the
      # child can still read by name. The read guard needs no path policy to
      # mask a credential region, which is the half this run can enforce. It
      # reads no `[tests]` table either: its children write nothing a layout
      # holds.
      #
      # @param journal [#<<] where a refusal or a mask is recorded
      # @return [#call] `worker_env -> stack`, a fresh one per call, every one
      #   over the same board
      def detached(journal:)
        inputs = Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: Unreleased,
                            sensitivity: Lain::Sensitivity::Policy::Null.instance,
                            test_layout: Middleware::GuardTestLayout::Run.undeclared,
                            policy: Middleware::Gate::ApproveAll.new, denial: Middleware::Gate::DENIAL,
                            bar: Middleware::WithholdAutomaticOutput::Bar.new)
        chronicle = Journaled.new(journal:)
        ->(worker_env) { working(chronicle, inputs, worker_env) }
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
          journal: chronicle.instrumentation.journal }
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
