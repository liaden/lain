# frozen_string_literal: true

module Lain
  class Provider
    class BedrockRaw < Provider
      # A thin subclass of the vendored Bedrock HTTP provider that exposes the
      # two round trips {BedrockRaw} needs, while REUSING the vendored Faraday
      # stack and SSE engine. It is a near-copy of {AnthropicRaw::Transport}, but
      # that one is `class Transport < Provider::HTTP::Providers::Anthropic` --
      # bound by inheritance to the direct-Anthropic backend (api.anthropic.com,
      # x-api-key). This one subclasses {Provider::HTTP::Providers::Bedrock} so it
      # inherits the Mantle endpoint and the bearer-token headers instead; the
      # inheritance is the whole difference, so the subclass cannot be shared.
      #
      # Like its sibling it deliberately does NOT go through the vendored
      # `complete`/`render_payload` or `stream_response`: the payload is already
      # rendered by {AnthropicEncoding} and each parsed SSE event is handed
      # straight out, so the block-preserving {AnthropicRaw::StreamAssembler} can
      # do the reassembly.
      class Transport < Provider::HTTP::Providers::Bedrock
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
