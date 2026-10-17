# frozen_string_literal: true

module Lain
  class Provider
    class Anthropic < Provider
      # The Provider's side of the faraday-retry seam: it journals every retry
      # as a {Telemetry::ProviderRetry}, and it owns the ATTEMPT BOUNDARIES of
      # the one in-flight round trip -- the live {Spool::RotatingFrame} is held
      # here so the retry hook can rotate it when faraday-retry abandons the
      # attempt underway. A retried attempt must never share a WAL frame with
      # the one it replaced (the byte-count check cannot catch two concatenated
      # attempts), and the transport must stay digest-blind, so the rotation
      # has to live on this side of the transport. One frame is live at a time
      # because a Provider is one round trip, never a loop.
      #
      # The main Agent's Provider and each subagent's share ONE
      # {Chronicle}-owned spool, so more than one round trip can be in flight
      # through this SAME tap from different fibers at once. The live frame
      # therefore CANNOT live in instance state: a retry firing for one request
      # would rotate whichever sibling last opened, re-enabling the very
      # concatenated-attempts frame the rotation exists to prevent. It is
      # threaded onto the request's Faraday context at open instead, and
      # {#retry_block} reaches ITS request's frame off the retried env.
      class RetryTap
        # @param spool [#open_frame] where each round trip's raw bytes are teed
        # @param channel [#<<] the live stream retries are narrated on
        # @param journal [#<<] the session's record, where each retry also lands
        def initialize(spool:, channel:, journal: Channel::Null::INSTANCE)
          @spool = spool
          @narration = RetryNarration.new(channel:, journal:)
        end

        # Opens the frame for one round trip and returns it; the Provider threads
        # it onto the request env, where {#retry_block} finds it again.
        def open_frame(request_digest:, stream:)
          Spool::RotatingFrame.new(spool: @spool, request_digest:, wire: stream ? "anthropic-sse" : "anthropic-json")
        end

        # Rotates the retried request's frame, tells its round trip's witness
        # what the abandoned attempt failed with -- faraday-retry hands the round
        # trip back only the last failure -- and journals.
        def retry_block
          lambda do |env:, retry_count:, exception:, will_retry_in:, **|
            frame_on(env)&.rotate
            witness_on(env)&.attempted(exception)
            @narration.retried(retry_count:, will_retry_in:, status: env[:status], exception:)
          end
        end

        # `options.max` is the RETRY count, not the ordinal of the attempt
        # that just failed; {RetryNarration#exhausted} adds the original try.
        def exhausted_block
          lambda do |env:, exception:, options:|
            @narration.exhausted(max: options.max, status: env[:status], exception:)
          end
        end

        private

        # `env[:request]` reads the RequestOptions on a real Faraday::Env and on
        # a plain-Hash test double alike; nil-safe so a request opened over the
        # Null spool simply does not rotate.
        def frame_on(env)
          context = env[:request]&.context
          context && context[:wal_frame]
        end

        # The round trip's {ErrorWrapping::WireWitness}, off its own key.
        def witness_on(env)
          context = env[:request]&.context
          context && context[:wire_witness]
        end
      end
    end
  end
end
