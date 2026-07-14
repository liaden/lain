# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # A thin subclass of the vendored HTTP provider base that exposes the one
      # non-streaming round trip {Ollama} needs, REUSING the vendored Faraday
      # stack (timeout, faraday-retry, JSON de/serialization, error mapping, the
      # injected-Sink logger). It deliberately does NOT go through the vendored
      # `complete`/`sync_response`: the payload is already rendered by
      # {Ollama::Encoding}, so the body is posted as-is and handed straight back.
      #
      # Unlike {Provider::HTTP::Providers::Anthropic} this is a LOCAL provider --
      # no api key, no auth header, no configuration requirement -- so `local?`
      # is true and `configuration_requirements` stays empty. Its
      # `ollama_api_base` Configuration option is registered at load (below) via
      # `register_provider_options` directly, NOT `Provider::HTTP::Provider.register`:
      # this is a Lain-native provider reusing the transport base, not a member
      # of the vendored slice's slug registry, so it takes the option seam
      # without adding a `resolve(:ollama)` entry the vendored code never looks up.
      class Transport < Provider::HTTP::Provider
        COMPLETION_PATH = "api/chat"
        DEFAULT_API_BASE = "http://localhost:11434"

        # One non-streaming round trip. `faraday.response :json` has already
        # parsed the body, so `#body` is a Hash.
        def sync_post(payload, headers = {})
          connection.post(COMPLETION_PATH, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
          end
        end

        def api_base
          @config.ollama_api_base || DEFAULT_API_BASE
        end

        class << self
          def configuration_options = %i[ollama_api_base]

          def local? = true
        end
      end
    end
  end
end

Lain::Provider::HTTP::Configuration.register_provider_options(
  Lain::Provider::Ollama::Transport.configuration_options
)
