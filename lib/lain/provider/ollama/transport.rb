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

        # One streaming round trip. Raw byte chunks (any TCP boundary) are yielded
        # to `on_chunk`; {StreamAssembler} owns the NDJSON line reassembly. Only
        # the vendored `on_data` byte-feeding is reused here, NOT the SSE engine
        # (`build_on_data_handler`), which folds every chunk through
        # `EventStreamParser` -- meaningless for `application/x-ndjson`. The
        # failed-response arm still routes through the vendored streaming error
        # handling so a non-2xx stream raises the same typed error the
        # non-streaming path would.
        def stream(payload, headers = {}, &on_chunk)
          connection.post(COMPLETION_PATH, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            install_on_data(req, &on_chunk)
          end
        end

        def api_base
          @config.ollama_api_base || DEFAULT_API_BASE
        end

        private

        # Reuses the version-correct `on_data` proc (Faraday 1 vs 2 arity differ)
        # from the vendored FaradayHandlers, feeding raw chunks straight to the
        # NDJSON assembler. `handle_failed_response`/`faraday_1?` resolve through
        # the mixed-in `Streaming` engine on the provider base. A deliberate
        # asymmetry rides along: a failed STREAM's message comes from the vendored
        # `handle_failed_response`/`parse_streaming_error` (generic wording), while
        # a failed sync post's comes from ErrorMiddleware's body text -- inherited
        # vendored behavior, same typed error class either way.
        def install_on_data(req, &on_chunk)
          buffer = +""
          handler = Provider::HTTP::Streaming::FaradayHandlers.build(
            faraday_v1: faraday_1?,
            on_chunk: ->(chunk, _env) { on_chunk.call(chunk) },
            on_failed_response: ->(chunk, env) { handle_failed_response(chunk, buffer, env) }
          )
          assign_on_data(req, handler)
        end

        # Faraday 1 takes `on_data` as a Hash key, Faraday 2 as an accessor.
        def assign_on_data(req, handler)
          if faraday_1?
            req.options[:on_data] = handler
          else
            req.options.on_data = handler
          end
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
