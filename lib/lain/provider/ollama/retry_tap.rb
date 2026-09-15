# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # The Provider's side of the faraday-retry seam: it journals every retry
      # as a {Telemetry::ProviderRetry}, and it owns the ATTEMPT BOUNDARIES of
      # one in-flight round trip -- an {Attempt} is what a retry ABANDONS, so
      # whatever the discarded attempt accumulated goes with it.
      #
      # Why it exists at all: `request_timeout` is 300s and `max_retries` is 3
      # with `:post` retryable, so a stalled server costs four attempts --
      # measured at over 400 seconds printing NOTHING, indistinguishable from
      # the one shape this arm is expected to have. An attempt boundary nobody
      # journals is a boundary nobody can see.
      #
      # == Why the live attempt CANNOT live in instance state
      #
      # The same argument {Anthropic::RetryTap} makes: a Provider is constructed
      # once and reused, and one instance can serve the chat tier and the
      # summarizer tier for a whole session, so more than one round trip can be
      # in flight through this SAME tap. An {Attempt} held in an ivar would let
      # a retry firing for round trip A abandon whichever sibling opened last.
      #
      # It binds HARDER here than it does for Anthropic. SSE carries a
      # `message_start` the assembler can re-sync on; Ollama's NDJSON carries no
      # equivalent marker, so a retried stream can only be told from the attempt
      # it replaced by this hook (a severed attempt plus a clean retry returned
      # both attempts' text concatenated, under a `done_reason` of "stop").
      # Abandoning the wrong round trip's attempt would therefore throw away a
      # live stream's bytes and splice the broken one anyway.
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
        # ONE PER ROUND TRIP, not one per attempt, despite the name: it is what
        # every attempt of a round trip is abandoned THROUGH, and it outlives
        # each of them. `#abandon` therefore fires once per retry, so a rollback
        # must survive being called three times for one `#complete`.
        #
        # **A rollback must not raise.** {RetryTap#retry_block} abandons before
        # it journals, so an exception here both loses the
        # {Telemetry::ProviderRetry} for that attempt and replaces the transport
        # error faraday-retry was carrying. The streaming assembler's reset is
        # bound by this: discarding a buffer cannot be allowed to fail.
        #
        # It also carries the round trip's {ErrorWrapping::WireWitness}, being
        # the one object every attempt of it is abandoned through. Handed over
        # after opening, so {#open_attempt}'s shape stays the rollback alone.
        class Attempt
          # Null Object: a round trip with nothing to discard is abandoned
          # exactly like one that has something, so no caller writes
          # `if rollback`.
          NOTHING_TO_DISCARD = -> {}.freeze

          def initialize(on_abandon = nil)
            @on_abandon = on_abandon || NOTHING_TO_DISCARD
            @witness = ErrorWrapping::WireWitness::Unwitnessed
          end

          def abandon = @on_abandon.call

          # @param witness [#attempted] the round trip's wire witness
          # @return [self]
          def witnessed_by(witness)
            @witness = witness
            self
          end

          # @param exception [Exception] what the abandoned attempt failed with
          def attempted(exception) = @witness.attempted(exception)
        end

        def initialize(channel:, spool: Spool::Null.new)
          @channel = channel
          @spool = spool
        end

        # Opens the boundary for ONE round trip and returns it; the Provider
        # threads it onto the request context, where {#retry_block} finds it
        # again (see {Transport}).
        def open_attempt(&on_abandon) = Attempt.new(on_abandon)

        # Opens the WAL frame for ONE round trip and returns it; like an
        # {Attempt} it is threaded onto the request context rather than held
        # here, for the same reentrancy reason, and {#retry_block} rotates ITS
        # request's frame off the retried env.
        #
        # A frame and an attempt are DELIBERATELY two objects on two context
        # keys: folding the rotation into `on_abandon` would put the
        # retried-stream discard and the rotation on one seam where either could
        # displace the other.
        def open_frame(request_digest:)
          Spool::RotatingFrame.new(spool: @spool, request_digest:)
        end

        # The block faraday-retry calls on every retry, and the ORDER ranks the
        # things it does. It ABANDONS the attempt (the discard that stops two
        # attempts sharing an assembler), it ROTATES this request's WAL frame (a
        # retried attempt's bytes must not concatenate onto the abandoned
        # attempt's inside one complete-marked frame, which the terminator's
        # byte count cannot catch), it tells the round trip's witness what the
        # abandoned attempt failed with, and only then does it JOURNAL.
        # The discard runs first because it is the older guarantee and the one a
        # regression here would silently reinstate.
        #
        # A CALLER'S CALLBACK IS COMPOSED, NEVER ALLOWED TO REPLACE. Wiring this
        # with `||=` was right while the block carried only telemetry; since the
        # streaming assembler arrived the cost is silent corruption. Measured on
        # a real socket: a config carrying its own `retry_block` returned a
        # severed attempt's text concatenated with its replacement's, under a
        # `stop_reason` of `:end_turn`, with nothing above the Provider able to
        # tell.
        #
        # `then_call` runs LAST because it is the only part of this lambda that
        # is not ours: an arbitrary callback that raises must not cost the
        # attempt its discard or its {Telemetry::ProviderRetry}.
        #
        # @param then_call [#call, nil] a caller-supplied retry callback, invoked
        #   with the same keywords faraday-retry passed.
        def retry_block(then_call: nil)
          lambda do |env:, retry_count:, exception:, will_retry_in:, **rest|
            attempt = attempt_on(env)
            attempt&.abandon
            frame_on(env)&.rotate
            attempt&.attempted(exception)
            @channel.push(Telemetry::ProviderRetry.new(attempt: retry_count + 1, will_retry_in:,
                                                       status: env[:status], reason: exception.class.name))
            then_call&.call(env:, retry_count:, exception:, will_retry_in:, **rest)
          end
        end

        # `options.max` is the RETRY count, not the ordinal of the attempt
        # that just failed -- an original try plus `max` retries is `max + 1`
        # attempts. Measured: a counting TCP listener saw 4 real attempts
        # rendered as "1, 2, 3, 3" because this pushed the retry count unchanged.
        def exhausted_block
          lambda do |env:, exception:, options:|
            @channel.push(Telemetry::ProviderRetry.new(attempt: options.max + 1, will_retry_in: nil,
                                                       status: env[:status], reason: exception.class.name))
          end
        end

        private

        # `env[:request]` reads the RequestOptions on a real Faraday::Env and on
        # a plain-Hash test double alike; nil-safe so a request that opened no
        # attempt -- the `/api/ps` probe -- still journals rather than crashing
        # on a missing context.
        def attempt_on(env)
          context = env[:request]&.context
          context && context[:retry_attempt]
        end

        # Read the same nil-safe way and off its own key -- see {#open_frame}
        # for why it is not the attempt's rollback. A request over the Null
        # spool still rotates; the Null frame discards, so no caller writes
        # `if spool`.
        def frame_on(env)
          context = env[:request]&.context
          context && context[:wal_frame]
        end
      end
    end
  end
end
