# frozen_string_literal: true

require "async"

module Lain
  module Oracle
    # Holds tool-result summaries keyed by the result's SOURCE DIGEST, and asks
    # for each on its own fiber so a slow local oracle never stalls the turn that
    # produced the source. An immutable source can never go stale, so the digest
    # is the right key: the same result content always addresses the same summary.
    #
    # Deliberately tier-agnostic -- `oracle` is anything answering
    # `#ask(inputs) -> Promise`. Journaling is NOT this object's job: wrap the
    # injected tier in {Recorded::Journaling} and every Q&A rides the existing
    # {Telemetry::OracleAnswer} path.
    #
    # CONTAINMENT is the point of the task boundary. A fire that raises dies with
    # its task: it holds nothing and never surfaces at the reactor. Oracles have
    # no rejection channel, so there is nowhere for the failure to go -- and a
    # seam that later reads {#held} treats an absent summary as a miss, falling
    # back to the deterministic record rather than a blocking summarize.
    #
    # A failed fire does NOT therefore journal nothing.
    # {Provider::Journaled} records the outbound request BEFORE dispatch and the
    # capacity gate sits INSIDE `Ollama#complete`, so a summary the endpoint
    # refuses leaves a {Telemetry::RequestSent} with no {Telemetry::OracleAnswer}
    # after it. That PAIR is the skip, and the shape to read the journal for: the
    # answer's absence is the signal. Only a fire that dies before the provider is
    # reached -- a half-written `.lain/summarizers.rb` -- journals nothing.
    class Eager
      # The slot the summarizer template reads its source text from. Fixing it
      # here keeps `#fire`'s two arguments -- a digest to key on and the text to
      # summarize -- free of the question's shape.
      DEFAULT_SLOT = :source

      # The tier this fires into. Readable because callers share ONE Eager and have
      # to be able to check they are looking at the same one.
      attr_reader :oracle

      # @param oracle [#ask] a tier answering `#ask(inputs) -> Promise`
      # @param slot [Symbol] the template slot the source text fills
      def initialize(oracle:, slot: DEFAULT_SLOT)
        @oracle = oracle
        @slot = slot
        @held = {}
        @fired = Set.new
      end

      # Spawn the summary of `text` on its own transient task and return at once
      # -- the turn that produced `text` never waits on the oracle. Fires at most
      # once per `digest`: a repeat is a cache hit, not a second call.
      #
      # With NO ambient reactor it is a graceful no-op: no spawn, no hold, the
      # digest stays unconsumed, nil returned -- an absent summary that reads as a
      # miss, exactly like one still in flight. That is what keeps the handler
      # chain runnable as plain synchronous Ruby.
      #
      # The task is TRANSIENT, so its lifetime is bounded by the ambient reactor's
      # and an unfinished fire is reaped when the scope ends. The agent-loop
      # reactor is long-lived, so a fire mounted there resolves normally; a DIRECT
      # caller inside a short-lived `Sync` may reap an in-flight fire, which is a
      # MISS, not an error. So the spawn belongs where a long-lived reactor is
      # already in scope, never inside an ephemeral gather task.
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
        rescue ScriptError, StandardError, SystemStackError
          # The task boundary is the containment: a failed fire holds nothing. It
          # may still have journaled its ATTEMPT -- see the class header.
          # Async::Stop is not a StandardError, so a stop flows past this rescue
          # and cancels the task quietly.
          #
          # The two families beside StandardError are both a half-written
          # `.lain/summarizers.rb` reaching here through the tier, the state the
          # DSL is in while a user is authoring it: {Summarizer::Base} raises
          # NotImplementedError (a ScriptError) for a method not written yet, and
          # a predicate that calls itself raises SystemStackError, which descends
          # straight from Exception. Containment covering only StandardError would
          # let either kill the turn that fired the summary.
          #
          # A predicate that never RETURNS is the mode no rescue reaches: the
          # spawn runs eagerly to its first yield point and a CPU loop has none,
          # so it blocks the observing turn.
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
