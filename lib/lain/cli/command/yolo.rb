# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/yolo on|off`: flips the LIVE gate through the {Approval::PolicySwitch}
      # the Gate already holds -- on swaps in {Gate::ApproveAll}, off restores
      # the session's {Approval::Queue}. The Gate itself stays construction-
      # fixed; the switch journals each flip attributed to this surface. In a
      # `--yolo` session no queue was ever wired, so `off` has nothing to
      # restore and refuses loudly rather than inventing a policy.
      class Yolo
        # The same signature Frontend::ApprovalPolicy signs decisions with: the
        # flip came from the human at the terminal.
        SURFACE = "tty"

        def initialize = freeze

        def name = "yolo"

        def usage = "/yolo on|off -- auto-approve gated tool calls, or restore the approval queue"

        def call(args, env)
          case args.strip.downcase
          when "on" then engage(env)
          when "off" then restore(env)
          else raise Error, "usage: /yolo on|off"
          end
        end

        private

        # Already-parked pendings stay FAIL-CLOSED: the flip changes the policy
        # future gated calls consult, it decides nothing retroactively -- and
        # between asks no watch surface runs, so an undrained pending would
        # quietly timeout-deny. The confirmation counts them and names the way
        # out, so the operator never learns that from a 300s-late denial.
        def engage(env)
          env.policy_switch.switch(Effect::Handler::Gate::ApproveAll.new, surface: SURFACE)
          confirmation = "yolo on -- gated tool calls auto-approve until /yolo off"
          parked = env.approvals.each.reject(&:decided?).size
          parked.zero? ? confirmation : "#{confirmation}\n#{parked} parked approvals remain -- /approve to drain"
        end

        # Restores the queue for FUTURE gated calls only: nothing already
        # approved (or already running) is revoked -- there is no un-approving
        # a dispatched effect, only refusing the next one.
        def restore(env)
          queue = env.approvals
          raise Error, "no approval queue in this session (started with --yolo); nothing to restore" \
            unless queue.respond_to?(:call)

          env.policy_switch.switch(queue, surface: SURFACE)
          "yolo off -- gated tool calls queue for approval again"
        end
      end
    end
  end
end
