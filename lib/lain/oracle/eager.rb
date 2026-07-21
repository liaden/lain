# frozen_string_literal: true

require "async"

module Lain
  module Oracle
    # Holds tool-result summaries keyed by the result's SOURCE DIGEST, and asks
    # for each on its own fiber so a slow local oracle never stalls the turn that
    # produced the source. An immutable source can never go stale, so the digest
    # is the right key: the same result content always addresses the same summary.
    #
    # It is deliberately tier-agnostic. `oracle` is any tier answering the
    # `#ask(inputs) -> Promise` message {Model} and {Heuristic} do -- Ollama-backed
    # {Model} in live use, {Mock}/{Heuristic} in specs. Journaling is NOT this
    # object's job: wrap the injected tier in {Recorded::Journaling} and every Q&A
    # rides the existing {Telemetry::OracleAnswer} path, so a {Recorded} tier
    # replays a fired summary with no live call and `#held` answers the recorded
    # one -- the same record/replay discipline the rest of the tier speaks.
    #
    # CONTAINMENT is the point of the task boundary. A fire that raises dies with
    # its task: it journals nothing (a journaling tier never reached its write),
    # holds nothing, and never surfaces at the reactor. Oracles have no rejection
    # channel, so there is nowhere for the failure to go but away -- and a seam
    # that later reads {#held} treats an absent summary as a miss and falls back to
    # the deterministic record alone, never a blocking summarize.
    class Eager
      # The slot the summarizer template reads its source text from. The injected
      # oracle's {Definition} names the same slot; fixing it here keeps `#fire`'s
      # two arguments -- a digest to key on and the text to summarize -- free of
      # the question's shape.
      DEFAULT_SLOT = :source

      # @param oracle [#ask] a tier answering `#ask(inputs) -> Promise`
      # @param slot [Symbol] the template slot the source text fills
      def initialize(oracle:, slot: DEFAULT_SLOT)
        @oracle = oracle
        @slot = slot
        @held = {}
        @fired = Set.new
      end

      # Spawn the summary of `text` on its own transient task and return the task
      # at once -- the turn that produced `text` never waits on the oracle. Fires
      # at most once per `digest`: a repeat is a cache hit, not a second call.
      #
      # A fire needs an ambient reactor to spawn into. With NONE, it is a graceful
      # no-op: no spawn, no hold, the digest stays unconsumed, and it returns nil
      # -- an absent summary that reads as a miss, exactly like one still in
      # flight. This is what keeps the handler chain runnable as plain synchronous
      # Ruby (5-0.2): a dispatch with no surrounding `Async` still completes and
      # returns its result unchanged; only the summary is skipped.
      #
      # The task is TRANSIENT, so its lifetime is bounded by the ambient reactor's:
      # it never keeps that reactor alive, and when the scope ends (or is stopped)
      # an unfinished fire is reaped with it. The agent-loop reactor is long-lived,
      # so a fire mounted there (ToolRunner post-dispatch) resolves normally; a
      # DIRECT caller inside a short-lived `Sync` that returns immediately may reap
      # an in-flight fire before it resolves -- that is a MISS, not an error. The
      # spawn therefore belongs where a long-lived reactor is already in scope, not
      # inside an ephemeral gather task that would reap it on return.
      #
      # @return [Async::Task, nil] the fire's task, or nil if this digest already
      #   fired OR no reactor is ambient (a caller wanting determinism -- a spec --
      #   may await a returned task)
      def fire(digest, text)
        task = Async::Task.current?
        return if task.nil?
        return if @fired.include?(digest)

        @fired << digest
        task.async(transient: true) do
          @held[digest] = @oracle.ask({ @slot => text }).await
        rescue StandardError
          # The task boundary is the containment: a failed fire holds nothing and
          # journals nothing. Async::Stop is not a StandardError, so a stop still
          # flows past this rescue and cancels the task quietly rather than raising
          # out at the reactor.
        end
      end

      # The completed summary for `digest`, or nil -- never blocks. A summary
      # still in flight, one whose fire failed, or a digest never fired all read
      # as absent, which the consuming seam treats as a miss.
      def held(digest)
        @held[digest]
      end
    end
  end
end
