# frozen_string_literal: true

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
      # Reused, not re-implemented: the live backends' first-token signal shares
      # ONE definition of when it fires and how a raising observer is isolated
      # (caught and journaled as {Telemetry::ObserverFailed}, never allowed to
      # cost #complete a response it already has). Mock firing the signal any
      # other way would let a test double diverge from the contract it exists to
      # stand in for.
      include StreamStartedSignal

      attr_reader :requests, :capabilities, :cache_profile

      # @param responses [Array<Lain::Response>] returned in order; the last one
      #   repeats once exhausted, so a loop that over-runs is visible as a
      #   repeated turn rather than a confusing nil.
      # @param capabilities [Array<Symbol>]
      # @param channel [Lain::Channel] where {StreamStartedSignal} pushes the
      #   {Telemetry::StreamStarted} and any {Telemetry::ObserverFailed}; the
      #   Null channel by default, so an unwired Mock is byte-identical to before.
      # @param cache_profile [Lain::CacheProfile] defaults to NO_CACHING --
      #   never Anthropic's numbers by accident, since a spec that forgot to
      #   inject one should see an honest "nothing caches", not a silently
      #   warm cache. A scheduler spec (CAC-3/4) that wants warm-cache
      #   behavior injects {CacheProfile::ANTHROPIC} explicitly.
      def initialize(responses: [], capabilities: CAPABILITIES.dup, channel: Channel::Null.instance,
                     cache_profile: CacheProfile::NO_CACHING)
        super()
        @responses = Array(responses)
        @capabilities = capabilities.map(&:to_sym).freeze
        @requests = []
        @channel = channel
        @cache_profile = cache_profile
      end

      def encode(request)
        request.cache_payload
      end

      # `on_stream_started` is CE-5's first-token signal (see
      # {StreamStartedSignal}). Mock fires it under the SAME two conditions the
      # live backends do -- an observer is wired AND `request.stream` is set --
      # so a fan-out driven through Mock exercises {Tools::Subagent::Stagger}'s
      # stream-start release, and a non-streaming request degrades exactly as a
      # provider that never signals. The fire routes through
      # {StreamStartedSignal#emit_stream_started}, so a raising observer is
      # isolated (journaled, not propagated) identically to live. When no
      # observer is wired the call is byte-identical to before.
      def complete(request, on_stream_started: nil)
        @requests << request
        raise Error, "Provider::Mock ran out of responses after #{@requests.size} calls" if @responses.empty?

        emit_stream_started(request, on_stream_started) if on_stream_started && request.stream
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
