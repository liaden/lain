# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/stop` at `you>`, where it never has an ask to stop.
      #
      # That reads like a joke and is the whole design: the repl dispatches a
      # line and the ask it starts completes inside that dispatch, so `you>` is
      # only ever read BETWEEN asks. A stop that can reach a run is typed at
      # the prompt the run parked on, where {Frontend::InputRail} lifts it off
      # the rail as a signal before any command sees it, or pressed as `s` at
      # the shutdown countdown. What is left here is the case a human hits by
      # reflex -- and it is registered so that reflex costs a sentence rather
      # than a model turn spent discovering the same thing.
      class Stop
        NOTHING_RUNNING = "no ask is running -- /stop at the prompt it parks on, or s at a countdown"

        def initialize = freeze

        def name = "stop"

        def usage = "/stop -- stop the ask in flight (at its prompt, or s at the countdown)"

        def call(_args, _env) = NOTHING_RUNNING
      end
    end
  end
end
