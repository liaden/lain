# frozen_string_literal: true

module Lain
  class Provider
    module Spool
      # One request's frame handle across retry attempts. The transport sees the
      # same append/close duck as a plain frame and stays digest-blind; the
      # Provider, which owns frame opening AND configures faraday-retry, calls
      # {#rotate} from its retry hook so a retried attempt never shares a frame
      # with the attempt it replaced. Without this, a stream dropped mid-flight
      # and retried would concatenate both attempts into one frame the byte-count
      # check cannot catch -- a complete-marked frame that lies. Aborted frames
      # are inert history; the last COMPLETE frame per digest is the response.
      class RotatingFrame
        def initialize(spool:, request_digest:)
          @spool = spool
          @request_digest = request_digest
          @frame = spool.open_frame(request_digest:)
        end

        def append(bytes)
          @frame.append(bytes)
          self
        end

        def close(complete:)
          @frame.close(complete:)
        end

        # A retry boundary: the attempt underway will never finish, so its frame
        # closes aborted (append-only -- nothing is truncated) and the retried
        # attempt gets a fresh frame under the same digest.
        def rotate
          @frame.close(complete: false)
          @frame = @spool.open_frame(request_digest: @request_digest)
          self
        end
      end
    end
  end
end
