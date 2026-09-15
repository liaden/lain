# frozen_string_literal: true

module Lain
  module Middleware
    # Tees the session scribe's {SessionRecord::Scribe#catch_up} at two points
    # of a turn-phase iteration.
    #
    # {#settle} writes the turn the agent just committed, before any tool it
    # called runs. Every record the tool round writes -- the turn's usage, a
    # spawn, a question -- cites that turn, and a tool can outlive the process
    # or park on a human, so a catch-up that waited for the iteration to return
    # left those records citing a turn no file held.
    #
    # {#call} catches up again once the iteration returns, which is what writes
    # the tool_result turn the round committed last -- per-ITERATION where the
    # repl's own catch_up is per-ask.
    #
    # The live head is read through an injected THUNK, never from the env:
    # {Agent#run_loop} builds the turn env BEFORE the step and merges only
    # response/settled back, so `env[:timeline]` is always the pre-step snapshot
    # and catching up on it would journal every iteration one step late. A
    # downstream raise skips the catch_up -- the interrupted iteration committed
    # nothing this middleware could see.
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

      # @param timeline [Lain::Timeline] the timeline holding the turn just
      #   committed, handed over rather than read, so the turn written is the
      #   turn committed
      def settle(timeline)
        @scribe.catch_up(timeline)
        self
      end
    end
  end
end
