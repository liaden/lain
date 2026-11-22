# frozen_string_literal: true

require "faraday"
require "openssl"

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
    # the provider's own APIError and survives only as its cause. A status is
    # asked after the transport, which has already taken the momentary and
    # server-side ones, so the statuses left are the request's own fault.
    module StopReason
      RULES = {
        stopped: ->(chain) { chain.any?(Lain::Stopped) },
        middleware: ->(chain) { chain.first.is_a?(Middleware::MemberFailed) },
        ceiling: ->(chain) { chain.first.is_a?(Budget::Exceeded) },
        over_window: ->(chain) { chain.first.is_a?(WindowExceeded) },
        stalled_stream: ->(chain) { chain.any?(Provider::HTTP::Streaming::StalledStreamError) },
        quota: ->(chain) { chain.any?(Provider::HTTP::QuotaError) },
        transport: ->(chain) { StopReason.transport?(chain.first) },
        rejected: ->(chain) { chain.first.is_a?(Provider::ErrorWrapping::Status) }
      }.freeze

      TORN = [:torn].freeze
      private_constant :TORN

      # @param error [Exception]
      # @return [Symbol] a member of {Telemetry::RunInterrupted::REASONS}
      def self.for(error)
        chain = Enumerator.produce(error, &:cause).take_while(&:itself)
        RULES.find(-> { TORN }) { |_reason, applies| applies.call(chain) }.first
      end

      # Only {CLI::Repl::Ask} reads it: the one other caller, Conductor#stopped, is handed a
      # {Lain::Stopped}, which never carries a status.
      # @param error [Exception]
      # @return [Integer, nil] the HTTP status the provider answered, if it did
      def self.status(error)
        error.status if error.is_a?(Provider::ErrorWrapping::Status)
      end

      DETAIL_LIMIT = 500

      # @param error [Exception]
      # @return [String, nil] the provider's own words for a quota stop, bounded
      def self.detail(error)
        quota_in_chain(error)&.message&.slice(0, DETAIL_LIMIT)
      end

      # @param error [Exception]
      # @param now [Time] the moment a retry-after in seconds counts from
      # @return [String, nil] an ISO 8601 time the quota resets, when the response says
      def self.reset_at(error, now: Time.now)
        headers = quota_in_chain(error)&.response&.then do |response|
          response.respond_to?(:headers) ? response.headers : nil
        end
        seconds = Provider::AnthropicWire::RESET_HEADER_PARSER.call(headers&.[]("retry-after"))
        (now + seconds).utc.iso8601 if seconds
      end

      def self.quota_in_chain(error)
        Enumerator.produce(error, &:cause).take_while(&:itself).find { |e| e.is_a?(Provider::HTTP::QuotaError) }
      end
      private_class_method :quota_in_chain

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

      # The one place this module reads a message. OpenSSL raises one class for
      # a handshake that refused a certificate and for a read that lost its
      # peer, and Ruby's binding prefixes the message with the libssl call that
      # failed, so the prefix is the only thing that tells the phases apart.
      READ_PHASE = "SSL_read"

      # A TLS connection that dropped where nothing below the Agent re-sends
      # it. Narrower than {.transport?} on purpose: Faraday already retries a
      # failed connection, a momentary status and a server-side one, and
      # retrying those again here would multiply its attempts by the Agent's. A
      # handshake failure is not a drop: a certificate refused once is refused
      # every time.
      #
      # @param error [Exception]
      # @return [Boolean]
      def self.dropped?(error)
        chain = Enumerator.produce(error, &:cause).take_while(&:itself)
        return false if chain.any?(Lain::Stopped)

        chain.drop_while { |cause| !cause.is_a?(Faraday::SSLError) }.any? { |cause| cause.message.start_with?(READ_PHASE) }
      end
    end
  end
end
