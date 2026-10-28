# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # What a run tells the operator about its flags before the first prompt:
      # a flag its provider ignores or cannot honour, said once rather than
      # silently dropped. Built from facts {Backend} has already resolved, so
      # saying them builds no provider.
      #
      # @!attribute [r] provider
      #   @return [String] the chat's provider, already validated
      # @!attribute [r] model
      #   @return [String] the chat's model
      # @!attribute [r] profile
      #   @return [RunProfile] what the flags resolved to
      # @!attribute [r] max_cost
      #   @return [Numeric, nil] `--max-cost` as typed
      # @!attribute [r] effort_rejected
      #   @return [Boolean] whether the hosted model refuses the asked effort
      # @!attribute [r] compacting
      #   @return [Boolean] whether a summarizer runs at all
      # @!attribute [r] summarizer
      #   @return [String] the summarizer tier's provider
      # @!attribute [r] summarizer_model
      #   @return [String] the summarizer tier's model
      StartupNotices = Data.define(:provider, :model, :profile, :max_cost, :effort_rejected, :compacting,
                                   :summarizer, :summarizer_model) do
        # @param tier [Array<String>] what the ollama tier itself says
        # @return [Array<String>]
        def ollama(tier) = [*tier, *unpriced_cost, *effort, *summarizer_tier]

        # @param dropped [Array<String>] the sampling flags the model refuses
        # @return [Array<String>]
        def hosted(dropped) = [*stranded_base, *unpriced_cost, *sampling(dropped), *effort, *summarizer_tier]

        private

        def summarizer_tier
          return unless compacting && (summarizer != provider || summarizer_model != model)

          "summaries run on #{summarizer} (#{summarizer_model}), not the #{provider} chat's #{model}"
        end

        def ollama? = OllamaTier::NAMES.include?(provider)

        def unpriced_cost
          return if max_cost.nil?

          PriceBook.default.price(model)
          nil
        rescue PriceBook::UnknownModel
          "--max-cost cannot bind: #{model} has no price, so its turns count as free"
        end

        def sampling(dropped)
          return if dropped.empty?

          flags = dropped.map { |flag| "--#{flag}" }.join(" and ")
          "#{model} takes no #{flags} (seed is not an Anthropic parameter at all): not sent"
        end

        def effort
          return unless profile.effort && (ollama? || effort_rejected)

          who = ollama? ? "the #{provider} chat" : model
          "--effort #{profile.effort} is ignored by #{who} and is not sent"
        end

        # Only a non-ollama chat can strand the flag, so the ollama arm never
        # reaches this.
        def stranded_base
          return unless profile.api_base

          if compacting && OllamaTier::NAMES.include?(summarizer)
            "--api-base reaches the #{summarizer} summarizer only, not the #{provider} chat"
          else
            "--api-base reaches nothing: the #{provider} chat does not use it and no summarizer runs on ollama"
          end
        end
      end
    end
  end
end
