# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # The one value a command reads its collaborators through -- the second
      # half of the single command message, call(args, env). {Wiring} assembles
      # it ONCE per run from the collaborators it already wired; a command never
      # reaches into the Repl (or anything else) for state, and a later command
      # card that needs a new reader adds it here plus one line in Wiring.
      #
      # Nil-free by contract: every reader answers a real collaborator (or the
      # one genuine Null Object, {YoloApprovals}), and a nil is refused loudly
      # at assembly -- no command ever writes `if env.thing`.
      Env = Data.define(:status, :sessions, :approvals, :supervisor,
                        :replies, :fork_point, :tmux_surface, :agent,
                        :policy_switch, :model_switch, :chronicle, :role_spawn) do
        def initialize(**readers)
          absent = readers.select { |_name, reader| reader.nil? }.keys
          raise ArgumentError, "Command::Env readers must not be nil (wire a Null collaborator): #{absent.inspect}" \
            unless absent.empty?

          super
        end
      end

      # Reopened after the `Data.define` block: per CLAUDE.md's known trap, a
      # constant written inside that block would land on the enclosing module
      # (Lain::CLI::Command), not on Env.
      class Env
        # --yolo wires no {Approval::Queue}; this answers the queue's read duck
        # with nothing parked, so an approvals-reading command degrades to an
        # honest empty listing instead of a nil guard. A GENUINE Null Object --
        # the domain reason it is empty is "under --yolo nothing queues", which
        # the name says. A module, like {Supervisor::Null}: no per-instance
        # state. Every OTHER Env reader is always wired live, so none needs a
        # Null -- they are required kwargs, and a mis-wire is a loud
        # ArgumentError at assembly, not a fail-open placeholder.
        module YoloApprovals
          def self.each(&block) = [].each(&block)
        end
      end
    end
  end
end
