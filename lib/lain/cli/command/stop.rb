# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/stop` at `you>`, where it never has an ASK to stop.
      #
      # That reads like a joke and is the whole design: the repl dispatches a
      # line and the ask it starts completes inside that dispatch, so `you>` is
      # only ever read BETWEEN asks. A stop that can reach a run is typed at
      # the prompt the run parked on, where {Frontend::InputRail} lifts it off
      # the rail as a signal before any command sees it, or pressed as `s` at
      # the shutdown countdown.
      #
      # A FLEET is a different story: an adopted actor is a sibling of every
      # ask, not a captive of one ({Supervisor}), so it keeps running with
      # nothing parked at `you>` to answer for it. This is the one place that
      # reaches it, which is why it reads {Supervisor#live} rather than
      # answering the same sentence unconditionally.
      #
      # It stops each running actor BY HAND (`worker.actor.stop`), never
      # `Supervisor#stop`: that call also ends the reactor those actors run
      # under (`@task.stop`), so a later actor-mode ask would find `#adopt`
      # refusing forever -- a promise correct at session CLOSE
      # ({CLI::Conductor}, {Repl::ConversationScope}) and wrong here, where the
      # chat goes on. Stopping only the rows it named also keeps the answer
      # honest: `Supervisor#stop` would farewell every non-retired row,
      # reaping a `:failed` one through the handoff and releasing a `:stopped`
      # one's lease, neither ever mentioned.
      class Stop
        NOTHING_RUNNING = "no ask is running -- /stop at the prompt it parks on, or s at a countdown"

        def initialize = freeze

        def name = "stop"

        def usage = "/stop -- stop the ask in flight (at its prompt, or s at the countdown), or the fleet if idle"

        def call(_args, env)
          live = env.supervisor.live
          return NOTHING_RUNNING if live.empty?

          live.each { |worker| worker.actor.stop }
          "no ask was running, but stopped #{names(live)}"
        end

        private

        def names(live) = live.map { |worker| label(worker) }.join(", ")

        # `role` and `worker_id` are rendered straight into a chat pane, so a
        # `nil` reads as `?` rather than an empty label, and a newline -- the
        # shape a wrong-but-not-malicious role string takes -- is flattened
        # before it can start what looks like a fresh line of output.
        def label(worker) = "#{sanitized(worker.role)} (#{sanitized(worker.worker_id)})"

        def sanitized(value)
          text = value.to_s.strip.tr("\n\r", "  ")
          text.empty? ? "?" : text
        end
      end
    end
  end
end
