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
                               Middleware::RedactSecretReads.new(**read_kwargs(chronicle, board)),
                               Middleware::WithholdSecretPaths.new(filter: path_filter(board))])
      end

      # The third guard covers the LISTING tools -- grep, glob, list_files --
      # which the other two do not touch: masking a region inside one file's
      # content and dropping a row out of an enumeration are different result
      # shapes, and the count of what was dropped has to be reported or the
      # agent reads the listing as complete.
      #
      # The filter is the BOARD's, and specifically its policy's own second
      # answer -- never one built here. {Sensitivity::Policy} exposes no
      # classifier, so this is the only filter reachable from a board, which is
      # what makes the failure it prevents unrepresentable rather than merely
      # untested: a filter constructed here over a freshly built classifier
      # would answer every message and judge a DIFFERENT set of paths than the
      # gate, so a run would enumerate paths its own gate refuses to read.
      #
      # It stops being a Null the moment a session resolves a project, because
      # {CLI::Wiring::BoardBuild} builds the classifier the policy wraps (T23).
      # A board that resolved none carries {Sensitivity::Policy::Null}, whose
      # filter is {Sensitivity::Filter::Null} -- so listings are byte-identical
      # to what that run produced before this boundary existed, and no line
      # here asks which case it is in.
      #
      # This SNAPSHOTS the filter, where the gate and
      # {Wiring::ToolsetBuild::LiveSensitivity} both re-read `board.sensitivity`
      # per call -- so the agreement above rests on that slot being
      # construction-fixed. It is: {Switchboard} exposes no writer for it, and
      # it is not one of the live slots the board re-binds in place (`toolset`
      # is, through {Switchboard#apply}, which is why the distinction is worth
      # stating rather than assuming). Should `sensitivity` ever become
      # re-bindable, this line has to become late too.
      def path_filter(board) = board.sensitivity.filter

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
