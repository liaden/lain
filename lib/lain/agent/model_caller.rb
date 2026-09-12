# frozen_string_literal: true

module Lain
  class Agent
    # Turns a rendered Request into a Response.
    #
    # Split out of the Agent for the same reason {ToolRunner} was: the model
    # round trip and its own middleware phase are no more the Agent's business
    # than the tool round trip's. Agent decides WHEN to call the model (the
    # state machine's `dispatch!`); this decides HOW.
    class ModelCaller
      # Readable so an Agent handed collaborators it did not build can check
      # what it was wired to.
      attr_reader :provider, :middleware

      def initialize(provider:, middleware: Middleware::Stack.new)
        @provider = provider
        @middleware = middleware
      end

      # `on_stream_started` (see {Provider::StreamStartedSignal}) is an
      # orchestration hook the stagger scheduler awaits, NOT request data, so it
      # rides the method arg and never enters the middleware env. Nil is INERT:
      # the provider is called with no second argument at all, so a `#complete`
      # taking only a request (Ollama, the default fan-out path) is
      # untouched.
      #
      # @param request [Lain::Request]
      # @param on_stream_started [#call, nil]
      # @return [Lain::Response]
      def call(request, on_stream_started: nil)
        @middleware.call({ request: }) do |inner|
          inner.merge(response: complete(inner.fetch(:request), on_stream_started))
        end.response
      end

      private

      def complete(request, on_stream_started)
        return @provider.complete(request) if on_stream_started.nil?

        @provider.complete(request, on_stream_started:)
      end
    end
  end
end
