# frozen_string_literal: true

module Lain
  module CLI
    # The tool phase's one guard, lifted out of {Wiring} the way {BaseTools},
    # {Switchboard}, {Command::Surface}, {Chronicle} and {ChatLaunch} were:
    # "what a chat refuses to let a tool write, and where that refusal is
    # recorded" is its own question, and both arms of the construction are
    # load-bearing in a way the one-liner it replaced could not show.
    #
    # {Middleware::RefuseSecretWrites} sits in the TOOL phase so a
    # credential-shaped memory_write is withheld before it ever reaches the
    # recorder: a memory, once indexed, replays into every future context, and
    # there is no un-indexing it.
    #
    # {Middleware::RedactSecretReads} is its mirror and sits beside it for the
    # same reason on the read side: an unreleased region masked out of a
    # `read_file` result never reaches an Event, a digest or the prompt-cache
    # prefix. The write guard is listed first only because reading order is
    # execution order and the two guard disjoint tools -- there is no ordering
    # constraint between them to get wrong.
    module ToolGuard
      module_function

      # @param chronicle [CLI::Chronicle] resolves where a refusal is recorded
      # @param board [CLI::Switchboard] holds the run's ONE region ledger and its
      #   approval queue. The board is passed rather than the two slots because
      #   "one ledger per run" is the board's invariant to keep, not this
      #   module's to re-derive.
      # @return [Middleware::Stack] the tool-phase stack, for the instrumentation
      def stack(chronicle, board)
        Middleware::Stack.new([Middleware::RefuseSecretWrites.new(**kwargs(chronicle)),
                               Middleware::RedactSecretReads.new(**read_kwargs(chronicle, board))])
      end

      # `--yolo` wires NO queue ({Switchboard#approvals} is nil), and the
      # stand-in is named HERE rather than defaulted inside the middleware: a
      # `queue:` with a default is how a forgotten injection becomes silent
      # approval, which is exactly the failure the ledger's own no-default rule
      # exists to prevent. Under the flag, approving is what every other gate in
      # the run already does.
      def read_kwargs(chronicle, board)
        { ledger: board.ledger,
          queue: board.approvals || Middleware::RedactSecretReads::Unqueued.instance,
          journal: chronicle.instrumentation.journal }
      end

      # The journal is READ off the chronicle's {Agent::Instrumentation}, which
      # is what made a `.slice(:journal)` necessary before it existed: the key had
      # to be OMITTED under --no-journal so RefuseSecretWrites' own
      # Channel::Null default applied, because an explicit `journal: nil` crashes
      # on `<<` at refusal time -- the worst possible moment. The value carries
      # that same Null, so the slice has nothing left to do.
      #
      # The `oracle:` arm is a CONTENTLESSNESS FLOOR, not a second secret
      # detector ({Oracle::MemorySave}): it declines a save with nothing in it
      # and journals that as a decline rather than under a PATTERNS name. It
      # abstains entirely for a guarded tool carrying no `body` at all, which
      # is what keeps improvement_write from being refused wholesale.
      def kwargs(chronicle)
        { oracle: Oracle::MemorySave::Gate.new, journal: chronicle.instrumentation.journal }
      end
    end
  end
end
