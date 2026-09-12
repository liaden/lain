# frozen_string_literal: true

module Lain
  module CLI
    module Command
      Env = Data.define(:status, :sessions, :approvals, :supervisor,
                        :replies, :fork_point, :tmux_surface, :agent,
                        :model_switch, :mode_switch, :chronicle, :role_spawn, :snapshots,
                        :epic_driver) do
        def initialize(**readers)
          absent = readers.select { |_name, reader| reader.nil? }.keys
          raise ArgumentError, "Command::Env readers must not be nil (wire a Null collaborator): #{absent.inspect}" \
            unless absent.empty?

          super
        end
      end

      # The one value a command reads its collaborators through -- the second
      # half of the single command message, call(args, env). {Wiring} assembles
      # it ONCE per run; a command never reaches into the Repl for state, and a
      # later command card that needs a new reader adds it here plus one line in
      # Wiring.
      #
      # Nil-free by contract: every reader answers a real collaborator (or the
      # one genuine Null Object, {NoApprovals}), and a nil is refused loudly at
      # assembly -- no command ever writes `if env.thing`. `mode_switch` sits
      # beside `model_switch` because both are delegating slots a command WRITES
      # and a construction-fixed collaborator READS. The gate's policy switch is
      # NOT a third: {CLI::Switchboard#apply} DERIVES it from a mode flip, so a
      # slot here would flatten a derived value next to its own cause and give
      # one slot two writers. `snapshots` is the {Agent::SnapshotSlot} the
      # Agent's deliveries write through, so `/undo` reads the very log they
      # feed.
      class Env
        # Reopened after the `Data.define` block: a constant written inside that
        # block would land on the enclosing module, not on Env.

        # An unattended run (`--non-interactive`) wires no {Approval::Queue} --
        # nobody is there to answer a parked call -- so this answers the queue's
        # read duck with nothing parked, and an approvals-reading command
        # degrades to an honest empty listing instead of a nil guard. Named for
        # the QUEUE'S ABSENCE rather than for whatever caused it: which flags
        # leave a run queueless has already changed once.
        #
        # This is a LISTING, not a verdict, so unlike its sibling stand-in
        # {Middleware::RedactSecretReads::Unqueued} -- which answers APPROVE for
        # the same queueless run -- it opens nothing. A module, like
        # {Supervisor::Null}: no per-instance state.
        module NoApprovals
          def self.each(&block) = [].each(&block)
        end

        # Four thin delegations, not memoized -- `agent`'s own `@timeline` is
        # reassigned every commit/rewind, so caching here would go stale mid-run.
        def head_digest = timeline.head_digest

        def timeline = agent.timeline

        def journal_path = chronicle.journal_path

        # Journal the CURRENT live Timeline durably. Answers the {Chronicle}
        # itself, so a caller chaining off the result reads the same way. NOT the
        # right tool for a caller that has already captured a Timeline of its own
        # to journal -- see {Rewind#moved}, the one site that calls
        # `chronicle.catch_up` directly instead.
        def checkpoint = chronicle.catch_up(timeline)
      end
    end
  end
end
