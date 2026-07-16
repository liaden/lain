# frozen_string_literal: true

module Lain
  class Provider
    class AnthropicRaw < Provider
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
      # T17w now lets the main Agent's Provider and each subagent's share ONE
      # {Chronicle}-owned spool, so more than one round trip -- each with its own
      # live frame -- can be in flight through this SAME {RetryTap} instance from
      # different fibers at once (a {Provider} is constructed once and reused).
      # The live frame therefore CANNOT live in instance state: a retry firing
      # for one request would rotate whichever sibling last opened, re-enabling
      # the very "complete frame that lies about concatenated attempts" the
      # rotation exists to prevent. Instead the frame is threaded onto the
      # request's Faraday context at open (see {Transport}), and {#retry_block}
      # reaches ITS request's frame off the retried env -- reentrant, per-request,
      # no shared mutable state. ({ResponseWal} itself serializes the bytes.)
      class RetryTap
        def initialize(spool:, channel:)
          @spool = spool
          @channel = channel
        end

        # Opens the frame for one round trip and returns it; the Provider threads
        # it onto the request env, where {#retry_block} finds it again.
        def open_frame(request_digest:)
          Spool::RotatingFrame.new(spool: @spool, request_digest:)
        end

        def retry_block
          lambda do |env:, retry_count:, exception:, will_retry_in:, **|
            frame_on(env)&.rotate
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

        # The RotatingFrame this request's transport stashed on its Faraday
        # context at frame-open ({Transport#sync_post}/{#stream}). `env[:request]`
        # reads the RequestOptions on a real Faraday::Env and on a plain-Hash
        # test double alike; nil-safe so a request opened over the Null spool (or
        # one whose context never took) simply does not rotate.
        def frame_on(env)
          context = env[:request]&.context
          context && context[:wal_frame]
        end
      end
    end
  end
end
