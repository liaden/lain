# frozen_string_literal: true

require_relative "../http"

module Lain
  class Provider
    class AnthropicRaw < Provider
      # A thin subclass of the vendored Anthropic HTTP provider that exposes the
      # two round trips {AnthropicRaw} needs, while REUSING the vendored Faraday
      # stack (faraday-retry, error mapping, the injected-Sink logger) and the SSE
      # engine (EventStreamParser feeding, chunk-boundary handling, streaming
      # error recognition).
      #
      # It deliberately does NOT go through the vendored `complete`/`render_payload`
      # or `stream_response`: that path builds and consumes the lossy `Message`,
      # and `stream_response` folds the stream through the flattening
      # `StreamAccumulator`. Here the payload is already rendered by
      # {AnthropicEncoding} and each parsed SSE event is handed straight out, so
      # the block-preserving {StreamAssembler} can do the reassembly instead.
      class Transport < Provider::HTTP::Providers::Anthropic
        # One non-streaming round trip. `faraday.response :json` has already parsed
        # the body, so `#body` is a Hash.
        def sync_post(payload, headers = {})
          connection.post(completion_url, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
          end
        end

        # One streaming round trip. Each parsed SSE `data` Hash is yielded to
        # `on_event`; the vendored `build_on_data_handler` still owns the byte
        # feeding and the failed-response path.
        def stream(payload, headers = {}, &on_event)
          connection.post(stream_url, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            install_on_data(req, &on_event)
          end
        end

        private

        def install_on_data(req, &on_event)
          handler = build_on_data_handler { |data| on_event.call(data) if data.is_a?(Hash) }
          if faraday_1?
            req.options[:on_data] = handler
          else
            req.options.on_data = handler
          end
        end
      end
    end
  end
end
