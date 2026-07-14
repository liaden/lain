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

      # @param request [Lain::Request]
      # @return [Lain::Response]
      def call(request)
        env = @middleware.call({ request: }) do |inner|
          inner.merge(response: @provider.complete(inner.fetch(:request)))
        end
        env.fetch(:response)
      end
    end
  end
end
