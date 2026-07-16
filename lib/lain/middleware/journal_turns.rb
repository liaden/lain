# frozen_string_literal: true

module Lain
  module Middleware
    # Tees the session scribe's {SessionRecord::Scribe#catch_up} after each
    # turn-phase iteration, so every committed turn is durable BEFORE the next
    # model call -- per-ITERATION granularity where the repl's own catch_up is
    # per-ask, which is what a SIGKILL mid-multi-tool-loop would otherwise lose.
    #
    # The live head is read through an injected THUNK (the exe's
    # `-> { agent.timeline }` idiom), never from the env: {Agent#run_loop}
    # builds the turn env BEFORE the step and merges only response/settled back,
    # so `env[:timeline]` is always the pre-step snapshot -- catching up on it
    # would journal every iteration one step late. Observes only: the env passes
    # through untouched, and a downstream raise skips the catch_up (the
    # interrupted iteration committed nothing this middleware could see).
    class JournalTurns < Base
      # @param scribe [#catch_up] the session scribe
      # @param timeline [#call] answers the live Timeline at the instant the
      #   iteration's downstream returned
      def initialize(scribe:, timeline:)
        @scribe = scribe
        @timeline = timeline
        super()
        freeze
      end

      def call(env, &app)
        result = downstream(env, &app)
        @scribe.catch_up(@timeline.call)
        result
      end
    end
  end
end
