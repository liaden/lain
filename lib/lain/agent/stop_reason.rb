# frozen_string_literal: true

module Lain
  class Agent
    # Why an ask stopped, as a {Telemetry::RunInterrupted} reason, read off the
    # error's TYPE and the types of its causes -- never its message, which is
    # the provider's to change.
    #
    # Distinct from {Lain::StopReason}, the wire's closed enum of why a MODEL
    # stopped generating: this is why the HARNESS stopped an ask.
    #
    # The order is part of the answer. A stop wins wherever it sits in the
    # causes, because an interrupt can unwind through any other failure. A stall
    # is asked before the transport, because a stall reaches an ask wrapped in
    # the provider's own APIError and survives only as its cause.
    module StopReason
      RULES = {
        stopped: ->(chain) { chain.any?(Lain::Stopped) },
        ceiling: ->(chain) { chain.first.is_a?(Budget::Exceeded) },
        over_window: ->(chain) { chain.first.is_a?(WindowExceeded) },
        stalled_stream: ->(chain) { chain.any?(Provider::HTTP::Streaming::StalledStreamError) },
        transport: ->(chain) { StopReason.transport?(chain.first) }
      }.freeze

      TORN = [:torn].freeze
      private_constant :TORN

      # @param error [Exception]
      # @return [Symbol] a member of {Telemetry::RunInterrupted::REASONS}
      def self.for(error)
        chain = Enumerator.produce(error, &:cause).take_while(&:itself)
        RULES.find(-> { TORN }) { |_reason, applies| applies.call(chain) }.first
      end

      # The two client statuses that fail for the moment rather than for the
      # request: a timeout and a rate limit answer differently a little later.
      MOMENTARY = [408, 429].freeze

      # A round trip that failed on its way to or from the server: one that
      # never reached the wire, an endpoint too busy to take it, one that got no
      # status back, a {MOMENTARY} status, or a server-side status. Any other
      # status is the request's own fault -- a bad key, a model the server does
      # not have -- and fails the same way every time.
      #
      # @param error [Exception]
      # @return [Boolean]
      def self.transport?(error)
        return true if error.is_a?(PreWire)
        return false unless error.is_a?(Provider::ErrorWrapping::RoundTripFailure)
        return true unless error.is_a?(Provider::ErrorWrapping::Status)

        MOMENTARY.include?(error.status) || error.status.to_i >= 500
      end
    end
  end
end
