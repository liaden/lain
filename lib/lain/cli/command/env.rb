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
      # Nil-free by contract: every reader answers a real collaborator or a
      # named Null standing in for one (Null Object over nil checks), and a nil
      # is refused loudly at assembly -- no command ever writes `if env.thing`.
      Env = Data.define(:status, :sessions, :approvals, :supervisor,
                        :replies, :fork_point, :tmux_surface, :agent,
                        :policy_switch, :model_switch, :chronicle) do
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
        # honest empty listing instead of a nil guard. A module, like
        # {Supervisor::Null}: there is no per-instance state.
        module NullApprovals
          def self.each(&block) = [].each(&block)
        end

        # The status-feed reader lands with the /status card (a one-line Wiring
        # diff swaps this out); until then the reader is nil-free through this
        # named placeholder, and a premature send fails loudly BY NAME.
        module NullStatus; end

        # T3's fork-point seam has not landed; same contract as {NullStatus}.
        module NullForkPoint; end

        # A wiring that flips no gate (specs, headless assemblies) leaves the
        # T14 policy switch out; a premature send fails loudly BY NAME, the
        # {NullStatus} contract. Wiring always passes the real switch.
        module NullPolicySwitch; end

        # Same contract as {NullPolicySwitch}, for /model's render-time slot.
        module NullModelSwitch; end
      end
    end
  end
end
