# frozen_string_literal: true

module Lain
  module CLI
    module Command
      Env = Data.define(:status, :sessions, :approvals, :supervisor,
                        :replies, :fork_point, :tmux_surface, :agent,
                        :policy_switch, :model_switch, :mode_switch, :chronicle, :role_spawn) do
        def initialize(**readers)
          absent = readers.select { |_name, reader| reader.nil? }.keys
          raise ArgumentError, "Command::Env readers must not be nil (wire a Null collaborator): #{absent.inspect}" \
            unless absent.empty?

          super
        end
      end

      # The one value a command reads its collaborators through -- the second
      # half of the single command message, call(args, env). {Wiring} assembles
      # it ONCE per run from the collaborators it already wired; a command never
      # reaches into the Repl (or anything else) for state, and a later command
      # card that needs a new reader adds it here plus one line in Wiring.
      #
      # Nil-free by contract: every reader answers a real collaborator (or the
      # one genuine Null Object, {YoloApprovals}), and a nil is refused loudly
      # at assembly -- no command ever writes `if env.thing`.
      # `mode_switch` sits beside its two siblings deliberately: all three are
      # delegating slots a command WRITES and a construction-fixed collaborator
      # READS, so they are one family, not three unrelated readers.
      class Env
        # Reopened after the `Data.define` block: per CLAUDE.md's known trap, a
        # constant written inside that block would land on the enclosing module
        # (Lain::CLI::Command), not on Env.

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

        # The class doc's Demeter point, made real: four thin delegations, not
        # memoized -- `agent`'s own `@timeline` is reassigned every
        # commit/rewind, so caching here would go stale mid-run.
        def head_digest = timeline.head_digest

        def timeline = agent.timeline

        def journal_path = chronicle.journal_path

        # Journal the CURRENT live Timeline durably -- what {Fork} and {Btw}
        # both did as a duplicated `chronicle.catch_up(agent.timeline)`
        # protocol before this landed. Answers the {Chronicle} itself (its
        # own `#catch_up` does the same), so a caller chaining off the result
        # reads the same way. NOT the right tool for a caller that has
        # already captured a Timeline of its own to journal -- see
        # {Rewind#moved}, the one site that calls `chronicle.catch_up`
        # directly instead.
        def checkpoint = chronicle.catch_up(timeline)
      end
    end
  end
end
