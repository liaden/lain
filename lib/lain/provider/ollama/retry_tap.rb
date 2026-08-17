# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # The Provider's side of the faraday-retry seam: it journals every retry
      # as a {Telemetry::ProviderRetry}, and it owns the ATTEMPT BOUNDARIES of
      # one in-flight round trip -- an {Attempt} is what a retry ABANDONS, so
      # whatever the discarded attempt accumulated goes with it.
      #
      # Ollama had neither, and `ollama.rb` used to state the first absence as
      # deliberate: free/local spend made invisible retries tolerable. The
      # 2026-08-17 QA run priced it. `request_timeout` is 300s and `max_retries`
      # is 3 with `:post` retryable, so a stalled server costs four attempts --
      # measured at over 400 seconds, printing NOTHING, which is
      # indistinguishable from the one shape this arm is expected to have (a
      # local model that thinks for six minutes). An attempt boundary nobody
      # journals is a boundary nobody can see.
      #
      # == Why the live attempt CANNOT live in instance state
      #
      # The same argument {Anthropic::RetryTap} makes, and it binds here too: a
      # Provider is constructed once and reused, and one instance can serve the
      # chat tier and the summarizer tier for a whole session, so more than one
      # round trip -- each with its own live attempt -- can be in flight through
      # this SAME tap. An {Attempt} held in an ivar would let a retry firing for
      # round trip A abandon whichever sibling opened last.
      #
      # It binds HARDER here than it does for Anthropic. SSE carries a
      # `message_start` the assembler can re-sync on; Ollama's NDJSON carries no
      # equivalent marker, so a retried stream can only be told from the attempt
      # it replaced by this hook (F7b -- a severed attempt plus a clean retry
      # returned both attempts' text concatenated, under a `done_reason` of
      # "stop"). Abandoning the wrong round trip's attempt would therefore throw
      # away a live stream's bytes and splice the broken one anyway.
      #
      # So: the Provider opens one {Attempt} per round trip, {Transport} threads
      # it onto that request's Faraday context, and {#retry_block} reaches ITS
      # request's attempt off the retried env -- reentrant, per-request, no
      # shared mutable state.
      class RetryTap
        # One round trip's attempt boundary. `on_abandon` is what faraday-retry
        # throwing an attempt away has to undo -- the partial state that must
        # not survive into the attempt replacing it.
        #
        # ONE PER ROUND TRIP, not one per attempt, despite the name: it is the
        # thing every attempt of a round trip is abandoned THROUGH, and it
        # outlives each of them. `#abandon` therefore fires once per retry, and
        # a rollback must be idempotent enough to survive being called three
        # times for one `#complete`.
        #
        # **A rollback must not raise.** {RetryTap#retry_block} abandons before
        # it journals, so an exception here both loses the
        # {Telemetry::ProviderRetry} for that attempt and replaces the transport
        # error faraday-retry was carrying -- the retry would surface as
        # whatever the rollback threw. T10's assembler reset is bound by this:
        # discarding a buffer cannot be allowed to fail.
        #
        # Nothing registers one on the ordinary paths yet: the sync body is a
        # single parsed Hash, so an abandoned attempt leaves nothing behind.
        # T10 registers the streaming assembler's reset here, which is the whole
        # reason this is a per-round-trip object rather than a counter.
        class Attempt
          # Null Object: a round trip with nothing to discard is abandoned
          # exactly like one that has something, so no caller writes
          # `if rollback`.
          NOTHING_TO_DISCARD = -> {}.freeze

          def initialize(on_abandon = nil)
            @on_abandon = on_abandon || NOTHING_TO_DISCARD
          end

          def abandon = @on_abandon.call
        end

        def initialize(channel:)
          @channel = channel
        end

        # Opens the boundary for ONE round trip and returns it; the Provider
        # threads it onto the request context, where {#retry_block} finds it
        # again (see {Transport}).
        def open_attempt(&on_abandon) = Attempt.new(on_abandon)

        def retry_block
          lambda do |env:, retry_count:, exception:, will_retry_in:, **|
            attempt_on(env)&.abandon
            @channel.push(Telemetry::ProviderRetry.new(attempt: retry_count + 1, will_retry_in:,
                                                       status: env[:status], reason: exception.class.name))
          end
        end

        def exhausted_block
          lambda do |env:, exception:, options:|
            @channel.push(Telemetry::ProviderRetry.new(attempt: options.max, will_retry_in: nil,
                                                       status: env[:status], reason: exception.class.name))
          end
        end

        private

        # The Attempt this request's transport stashed on its Faraday context.
        # `env[:request]` reads the RequestOptions on a real Faraday::Env and on
        # a plain-Hash test double alike; nil-safe so a request that opened none
        # -- the `/api/ps` probe, or a spec injecting its own `config:` -- still
        # journals rather than crashing on a missing context.
        def attempt_on(env)
          context = env[:request]&.context
          context && context[:retry_attempt]
        end
      end
    end
  end
end
