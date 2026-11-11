# frozen_string_literal: true

require "delegate"

module Lain
  module CLI
    class Backend
      # A secondary model tier's provider, model and runner options, resolved
      # when asked rather than when built, so a tier that follows the chat
      # follows `/model` and carries the options the chat's runner holds.
      #
      # Its provider is the one place a tier's answer is paid: journaled once
      # as the role's, and its dollars counted toward the chat's `--max-cost`.
      class Tier
        # A provider whose every answer is handed to a payer after it arrives.
        class Paying < SimpleDelegator
          # @param provider [Provider]
          # @param payer [#call] `(request, response)`
          def initialize(provider, payer)
            super(provider)
            @payer = payer
          end

          # @param request [Lain::Request]
          # @return [Response] the wrapped provider's own, untouched
          def complete(request, **)
            __getobj__.complete(request, **).tap { |response| @payer.call(request, response) }
          end
        end

        # @param role [Symbol] who the tier's requests are journaled as sent by
        # @param backend [Backend]
        # @param model [:follow, String] `:follow` asks whatever model the chat is on; a string stays pinned
        # @param queue [Boolean] whether the provider waits for a slot rather than skipping
        # @param arm [String, nil] the provider the tier dials, as `--provider` spells it; the chat's when nil
        def initialize(role:, backend:, model:, queue:, arm: nil)
          @role = role
          @backend = backend
          @model = model
          @queue = queue
          @arm = arm
        end

        # @return [Provider::Journaled] over a provider that pays each answer
        def provider
          @provider ||= Provider::Journaled.new(provider: Paying.new(bare_provider, method(:paid)),
                                                journal: Summarizer::RunJournal.new(@backend.journal_slot),
                                                requester: @role)
        end

        # @return [String]
        def model = following? ? @backend.attachment.model : @model

        # A followed model is the chat's own runner's, so the chat's options
        # are asked for on the launch model: `/model` swaps only the name.
        #
        # @return [Hash{String=>Object}]
        def extra = @backend.arm_tier_options(following? ? @backend.model : @model, arm: @arm)

        # @param definition [Oracle::Definition] the question the oracle answers
        # @param max_tokens [Integer] the reply ceiling
        # @return [Oracle::Model] over this tier's journaled provider, asking its live model and options
        def oracle(definition:, max_tokens:)
          Oracle::Model.new(definition:, provider:, max_tokens:, model: -> { model }, extra: -> { extra })
        end

        private

        def bare_provider = @backend.provider(**arm_name, requester: @role, queue: @queue)

        # Keyed by the request, since a tier commits no turn.
        def paid(request, response)
          spent = Budget::Spent.of(response, prices: PriceBook.default, clock: -> { Time.now.utc })
          @backend.attachment.spend.pay(spent)
          @backend.journal << Telemetry::TurnUsage.new(digest: request.digest, model: response.model,
                                                       stop_reason: response.stop_reason,
                                                       usage: response.usage.to_h, requester: @role)
        end

        def following? = @model == :follow

        def arm_name = @arm ? { name: @arm } : {}
      end
    end
  end
end
