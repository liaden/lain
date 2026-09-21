# frozen_string_literal: true

module Lain
  module Telemetry
    # An injected observer callback raised instead of running cleanly. A
    # caller-supplied hook is not allowed to cost a round trip its Response just
    # because the hook is buggy -- but a swallowed exception is a lie by
    # omission on a bench whose whole point is an honest record, so the failure
    # lands here instead of vanishing. `message` is the exception's own message
    # and not a backtrace: attribution, not diagnostics.
    ObserverFailed = Data.define(:hook, :digest, :message) do
      include Journalable

      def initialize(hook:, digest:, message:)
        super(hook: hook.to_sym, digest: digest.dup.freeze, message: message.to_s.dup.freeze)
      end
    end
  end
end
