# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # Namespace for wire-protocol implementations, one per backend. Only
      # Anthropic is vendored in this slice.
      module Providers
        # Anthropic Claude API wire protocol: the endpoint, headers and streaming
        # hooks `Provider::Anthropic::Transport` builds on.
        #
        # Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/providers/anthropic.rb.
        # Changed: RubyLLM:: -> Lain::Provider::HTTP::.
        #
        # `anthropic/streaming.rb` mixes itself in as it loads. Including it from
        # here instead is a cycle -- it reopens this class, so the loader could
        # reach this file's `include` while that require is still in flight. That
        # is safe only because `lib/lain.rb` eager loads every file: autoloaded
        # alone, this class would lack the streaming hooks and fail on a request.
        class Anthropic < Provider
          def api_base
            @config.anthropic_api_base || "https://api.anthropic.com"
          end

          def headers
            {
              "x-api-key" => @config.anthropic_api_key,
              "anthropic-version" => "2023-06-01"
            }
          end

          class << self
            def configuration_options
              %i[anthropic_api_key anthropic_api_base]
            end

            def configuration_requirements
              %i[anthropic_api_key]
            end
          end

          private

          # Messages is the one endpoint lain posts to, for sync and streaming alike.
          def completion_url
            "v1/messages"
          end
        end
      end
    end
  end
end

Lain::Provider::HTTP::Provider.register(:anthropic, Lain::Provider::HTTP::Providers::Anthropic)
