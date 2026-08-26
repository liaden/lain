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
    module ToolGuard
      module_function

      # @param chronicle [CLI::Chronicle] resolves where a refusal is recorded
      # @param board [CLI::Switchboard] holds the run's ONE region ledger and
      #   its approval queue, passed rather than its two slots because "one
      #   ledger per run" is the board's invariant, not this module's.
      # @return [Middleware::Stack] the tool-phase stack, for the instrumentation
      def stack(chronicle, board)
        Middleware::Stack.new([Middleware::RefuseSecretWrites.new(**kwargs(chronicle)),
                               Middleware::RedactSecretReads.new(**read_kwargs(chronicle, board)),
                               Middleware::WithholdSecretPaths.new(filter: path_filter(board))])
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
      def path_filter(board) = board.sensitivity.filter

      # An unattended run wires NO queue ({Switchboard#approvals} is nil), and
      # the stand-in is named HERE rather than defaulted inside the middleware:
      # a `queue:` with a default is how a forgotten injection becomes silent
      # approval. The stand-in approves, which
      # {Middleware::RedactSecretReads::Unqueued} records as the run's one
      # fail-open.
      def read_kwargs(chronicle, board)
        { ledger: board.ledger,
          queue: board.approvals || Middleware::RedactSecretReads::Unqueued.instance,
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
