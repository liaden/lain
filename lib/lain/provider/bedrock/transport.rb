# frozen_string_literal: true

module Lain
  class Provider
    class Bedrock < Provider
      # A thin subclass of the vendored Bedrock HTTP provider that exposes the
      # two round trips {Bedrock} needs, while REUSING the vendored Faraday
      # stack and SSE engine. It is a near-copy of {Anthropic::Transport}, but
      # that one is `class Transport < Provider::HTTP::Providers::Anthropic` --
      # bound by inheritance to the direct-Anthropic backend (api.anthropic.com,
      # x-api-key). This one subclasses {Provider::HTTP::Providers::Bedrock} so it
      # inherits the Mantle endpoint and the bearer-token headers instead; the
      # inheritance is the whole difference, so the subclass cannot be shared.
      #
      # Like its sibling it deliberately does NOT go through the vendored
      # `complete`/`render_payload` or `stream_response`: the payload is already
      # rendered by {AnthropicEncoding} and each parsed SSE event is handed
      # straight out, so the block-preserving {Anthropic::StreamAssembler} can
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
        # feeding and the failed-response path, and {Streaming#post_stream}
        # owns the end-of-stream flush -- without which an `event: error` the
        # server never terminated with a blank line stays buffered in the SSE
        # parser and the overload comes back as an empty, successful turn.
        def stream(payload, headers = {}, &on_event)
          on_data = build_on_data_handler { |data| yield data if data.is_a?(Hash) }
          post_stream(connection, stream_url, payload, on_data) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
          end
        end
      end
    end
  end
end
