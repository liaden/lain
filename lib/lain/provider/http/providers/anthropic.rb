# frozen_string_literal: true

require "json"

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

          def stream_url
            completion_url
          end

          def parse_streaming_error(data)
            error_data = JSON.parse(data)
            return unless error_data["type"] == "error"

            case error_data.dig("error", "type")
            when "overloaded_error"
              [529, error_data["error"]["message"]]
            else
              [500, error_data["error"]["message"]]
            end
          end
        end
      end
    end
  end
end

# Eager load is what guarantees this runs before anything reads Configuration.options.
Lain::Provider::HTTP::Configuration.register_provider_options(
  Lain::Provider::HTTP::Providers::Anthropic.configuration_options
)
