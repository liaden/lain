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
      class RetryTap
        def initialize(spool:, channel:)
          @spool = spool
          @channel = channel
        end

        # Opens the frame for one round trip and keeps it live for {#retry_block}.
        def open_frame(request_digest:)
          @live = Spool::RotatingFrame.new(spool: @spool, request_digest:)
        end

        def release
          @live = nil
        end

        def retry_block
          lambda do |env:, retry_count:, exception:, will_retry_in:, **|
            @live&.rotate
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
      end
    end
  end
end
