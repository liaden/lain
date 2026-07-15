# frozen_string_literal: true

# AWS Bedrock via the Anthropic "Mantle" endpoint. NOT a vendored file: the
# Mantle endpoint speaks the plain Anthropic Messages API over SSE, so payload
# rendering and chunk parsing are inherited wholesale from the vendored
# Anthropic backend. Only two things differ on the wire -- the endpoint host
# (derived from the region) and the auth scheme (a bearer token, not an
# x-api-key) -- so those are the only two methods overridden here.
#
# bedrock_region is a required option, not just bedrock_api_key: the endpoint
# host is derived from it, so a missing region is as fatal as a missing key and
# `ensure_configured!` must name both. Env-var defaulting for these options is
# deliberately absent at this layer (Configuration has no ENV defaults for
# provider options); it lives at the provider layer instead.
module Lain
  class Provider
    module HTTP
      module Providers
        # Anthropic models served through AWS Bedrock's Mantle endpoint. Same
        # Messages API on the wire as the Anthropic backend it subclasses; only
        # the endpoint host and the auth scheme differ.
        class Bedrock < Anthropic
          def api_base
            @config.bedrock_api_base || "https://bedrock-mantle.#{@config.bedrock_region}.api.aws/anthropic"
          end

          def headers
            {
              "Authorization" => "Bearer #{@config.bedrock_api_key}",
              "anthropic-version" => "2023-06-01"
            }
          end

          class << self
            def configuration_options
              %i[bedrock_api_key bedrock_api_base bedrock_region]
            end

            def configuration_requirements
              %i[bedrock_api_key bedrock_region]
            end
          end
        end
      end
    end
  end
end

Lain::Provider::HTTP::Provider.register(:bedrock, Lain::Provider::HTTP::Providers::Bedrock)
