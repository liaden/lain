# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # A secondary model tier's provider, model and runner options, resolved
      # when asked rather than when built, so a tier that follows the chat
      # follows `/model` and carries the options the chat's runner holds.
      class Tier
        # @param role [Symbol] who the tier's requests are journaled as sent by
        # @param backend [Backend]
        # @param model [:follow, String] `:follow` asks whatever model the chat is on; a string stays pinned
        # @param queue [Boolean] whether the provider waits for a slot rather than skipping
        def initialize(role:, backend:, model:, queue:)
          @role = role
          @backend = backend
          @model = model
          @queue = queue
        end

        # For a caller that journals its own requests, so none is recorded twice.
        #
        # @return [Provider]
        def bare_provider = @bare_provider ||= @backend.provider(requester: @role, queue: @queue)

        # @return [Provider::Journaled]
        def provider
          @provider ||= Provider::Journaled.new(provider: bare_provider,
                                                journal: Summarizer::RunJournal.new(@backend.journal_slot),
                                                requester: @role)
        end

        # @return [String]
        def model = following? ? @backend.live_model : @model

        # A followed model is the chat's own runner's, so the chat's options
        # are asked for on the launch model: `/model` swaps only the name.
        #
        # @return [Hash{String=>Object}]
        def extra = @backend.chat_tier_options(following? ? @backend.model : @model)

        # @param request [Lain::Request]
        # @return [Response] the answer, its payment recorded beside its request
        def ask(request)
          provider.complete(request).tap do |response|
            @backend.journal << Telemetry::TurnUsage.new(digest: request.digest, model: response.model,
                                                         stop_reason: response.stop_reason,
                                                         usage: response.usage.to_h, requester: @role)
          end
        end

        private

        def following? = @model == :follow
      end
    end
  end
end
