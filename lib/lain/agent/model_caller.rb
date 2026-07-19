# frozen_string_literal: true

module Lain
  class Agent
    # Turns a rendered Request into a Response.
    #
    # Split out of the Agent for the same reason {ToolRunner} was: the model
    # round trip, and ITS OWN middleware phase, are not the Agent's business
    # any more than the tool round trip's are -- Agent decides WHEN to call the
    # model (the state machine's `dispatch!`); this decides HOW. Threading
    # `:request`/`:response` through `@middleware` here is the same in/out
    # shape {ToolRunner} uses for `:effect`/`:result`.
    class ModelCaller
      attr_reader :provider

      def initialize(provider:, middleware: Middleware::Stack.new)
        @provider = provider
        @middleware = middleware
      end

      # `on_stream_started` is CE-5's first-token observer (see
      # {Provider::StreamStartedSignal}) -- an orchestration hook the stagger
      # scheduler awaits, NOT request data, so it rides the method arg and never
      # enters the middleware env. It defaults to nil and is INERT then: the
      # provider is called with no second argument at all, byte-identically to
      # before, so a provider whose `#complete` takes only a request (Bedrock,
      # Ollama, the default fan-out path) is untouched. Only a wired observer
      # forwards the kwarg, and only providers that accept it are ever handed it.
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
