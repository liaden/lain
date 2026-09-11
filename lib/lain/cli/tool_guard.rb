# frozen_string_literal: true

module Lain
  module CLI
    # The tool phase's one guard: what a chat refuses to let a tool write, and
    # where that refusal is recorded.
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
    # A child runs the same stack: the spawn seam carries a thunk over it, so
    # every child is guarded over its parent's board ({.child_stack}). A run
    # with no chat to borrow a board from builds its own through {.detached}.
    module ToolGuard
      # Everything the guards are built over, as ONE value: the run's one
      # region ledger, its approval queue (nil when nobody attends), its path
      # policy, and its test layout run. A {Switchboard} holds one
      # ({Switchboard#guard_inputs}); a run with no chat builds its own.
      Inputs = Data.define(:ledger, :approvals, :sensitivity, :test_layout)

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
        layered(chronicle, inputs, [inputs.test_layout.root])
      end

      # A child's stack: the parent's, guard for guard, except that a child
      # leased into a checkout of its own writes THERE, so its layout guard
      # holds that checkout's root beside the project's.
      #
      # @param chronicle [CLI::Chronicle] as on {.stack}
      # @param board [CLI::Switchboard] as on {.stack}
      # @param worker_env [WorkerEnv] the environment the child runs in
      # @return [Middleware::Stack]
      def child_stack(chronicle, board, worker_env) = working(chronicle, board.guard_inputs, worker_env)

      # A worker's stack, over the inputs it is guarded by and the checkout
      # its environment names, if its lease cut one.
      def working(chronicle, inputs, worker_env)
        layered(chronicle, inputs, inputs.test_layout.roots_for(worker_env))
      end

      # The four guards over one set of inputs, the layout held at `roots`.
      def layered(chronicle, inputs, roots)
        Middleware::Stack.new([Middleware::RefuseSecretWrites.new(**kwargs(chronicle)),
                               Middleware::RedactSecretReads.new(**read_kwargs(chronicle, inputs)),
                               Middleware::WithholdSecretPaths.new(filter: path_filter(inputs)),
                               Middleware::GuardTestLayout.new(run: inputs.test_layout, roots:,
                                                               journal: chronicle.instrumentation.journal)])
      end

      # The guard for a run with no chat, as the thunk a spawn seam carries.
      # The board is built ONCE, here, so every child the run spawns releases
      # into one ledger.
      #
      # Its path policy is the Null, matching the gate such a run's children
      # are spawned behind ({Tools::Subagent::UNJUDGED}): a listing filtered
      # through a policy the gate never consults would hide a path the child
      # can still read by name. The read guard needs no path policy to mask a
      # credential region, which is the half this run can enforce. It reads
      # no `[tests]` table either: its children write nothing a layout holds.
      #
      # @param journal [#<<] where a refusal or a mask is recorded
      # @return [#call] `worker_env -> stack`, a fresh one per call, every one
      #   over the same board
      def detached(journal:)
        inputs = Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: Unreleased,
                            sensitivity: Lain::Sensitivity::Policy::Null.instance,
                            test_layout: Middleware::GuardTestLayout::Run.undeclared)
        chronicle = Journaled.new(journal:)
        ->(worker_env) { working(chronicle, inputs, worker_env) }
      end

      # The third guard covers the LISTING tools, which the other two do not
      # touch: dropping a row out of an enumeration is a different result shape
      # from masking a region inside one file's content.
      #
      # The filter is the BOARD's own, never one built here. A filter over a
      # freshly built classifier would judge a DIFFERENT set of paths than the
      # gate, so a run would enumerate paths its own gate refuses to read;
      # {Sensitivity::Policy} exposes no classifier, which is what makes that
      # unrepresentable rather than merely untested.
      #
      # It SNAPSHOTS the filter where the gate re-reads `board.sensitivity` per
      # call, so that agreement rests on the slot being construction-fixed:
      # {Switchboard} exposes no writer for it and does not re-bind it. Should
      # it ever become re-bindable, this line has to become late too.
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
