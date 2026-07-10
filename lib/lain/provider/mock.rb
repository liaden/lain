# frozen_string_literal: true

require_relative "../provider"

module Lain
  class Provider
    # A provider that never touches the network.
    #
    # It exists so the Agent's state machine can be driven through every
    # `stop_reason` -- including `:refusal` and `:pause_turn`, which are hard to
    # provoke against a live API -- and so the loop's correctness gates can be
    # asserted without spending tokens. Requests are recorded in order, which is
    # what lets a spec check that all tool_results came back in ONE user message.
    #
    # Capabilities are configurable: a spec can hand the Agent a provider that
    # lacks `:prompt_caching` and assert the degradation is recorded rather than
    # silently ignored.
    class Mock < Provider
      attr_reader :requests, :capabilities

      # @param responses [Array<Lain::Response>] returned in order; the last one
      #   repeats once exhausted, so a loop that over-runs is visible as a
      #   repeated turn rather than a confusing nil.
      # @param capabilities [Array<Symbol>]
      def initialize(responses: [], capabilities: CAPABILITIES.dup)
        super()
        @responses = Array(responses)
        @capabilities = capabilities.map(&:to_sym).freeze
        @requests = []
      end

      def encode(request)
        request.cache_payload
      end

      def complete(request)
        @requests << request
        raise Error, "Provider::Mock ran out of responses after #{@requests.size} calls" if @responses.empty?

        @responses.size > 1 ? @responses.shift : @responses.first
      end

      # The last request this provider was asked to complete, which is the one a
      # spec almost always wants to assert against.
      def last_request
        @requests.last
      end

      def call_count
        @requests.size
      end
    end
  end
end
