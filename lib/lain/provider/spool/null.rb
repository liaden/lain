# frozen_string_literal: true

module Lain
  class Provider
    # A spool is where a Provider hands raw response bytes for durable capture.
    # The duck is one message -- `open_frame(request_digest:)` -> a frame handle
    # that answers `append(bytes)` and `close(complete:)`. {ResponseWal} is the
    # real implementation; this namespace holds the Null Object.
    module Spool
      # The default spool: opening a frame yields one that discards every byte,
      # so the transport tees unconditionally and no WAL file is ever created
      # when spooling is off. No caller writes `if spool`.
      class Null
        # A no-op frame handle. Satisfies the same duck as a {ResponseWal}
        # frame and sends the bytes nowhere.
        class Frame
          def append(_bytes) = self
          def close(**) = nil
        end

        def open_frame(**) = Frame.new
      end
    end
  end
end
