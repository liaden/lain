# frozen_string_literal: true

require "faraday"

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
      #
      # == Spooling raw bytes to the WAL
      #
      # Both round trips accept an opened {ResponseWal::Frame} (a {Spool::Null}
      # frame by default). The Provider owns the frame -- it computed the request
      # digest the frame is keyed by -- and the transport only appends the bytes
      # it sees off the wire and closes on a clean end. The two paths reach those
      # bytes differently: streaming tees every raw `on_data` chunk before the SSE
      # parser touches it; the sync path cannot use `on_data` (it nils the parsed
      # body the error middleware still needs), so it rides {WalResponseTee}, a
      # response middleware that copies `env.body` while it is still the wire
      # string.
      class Transport < Provider::HTTP::Providers::Anthropic
        # One non-streaming round trip. `faraday.response :json` has already parsed
        # the body, so `#body` is a Hash; {WalResponseTee} captured the wire bytes
        # for `frame` earlier in the same response, before that parse.
        def sync_post(payload, headers = {}, frame: Spool::Null::Frame.new)
          response = connection.post(completion_url, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            req.options.context = (req.options.context || {}).merge(wal_frame: frame)
          end
          frame.close(complete: true)
          response
        end

        # One streaming round trip. Each parsed SSE `data` Hash is yielded to
        # `on_event`; the vendored `build_on_data_handler` still owns the byte
        # feeding and the failed-response path, and each raw chunk is teed to
        # `frame` on the way in.
        def stream(payload, headers = {}, frame: Spool::Null::Frame.new, &on_event)
          connection.post(stream_url, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            install_on_data(req, frame, &on_event)
          end
          frame.close(complete: true)
        end

        private

        def install_on_data(req, frame, &on_event)
          handler = build_on_data_handler { |data| on_event.call(data) if data.is_a?(Hash) }
          teed = tee_chunks(handler, frame)
          if faraday_1?
            req.options[:on_data] = teed
          else
            req.options.on_data = teed
          end
        end

        # Wraps the SSE on_data handler so the verbatim wire chunk reaches the WAL
        # before it is parsed; the splat forwards Faraday's version-specific arity
        # (`|chunk, size|` on 1, `|chunk, bytes, env|` on 2) through untouched.
        def tee_chunks(handler, frame)
          proc do |chunk, *rest|
            frame.append(chunk)
            handler.call(chunk, *rest)
          end
        end
      end

      # Copies the raw HTTP response body -- `env.body` BEFORE the JSON middleware
      # parses it -- into the WAL frame carried on the request context. A no-op
      # unless a frame is present, so every non-recording request, and every other
      # provider sharing the stack, is unaffected. It must sit BELOW `response
      # :json` so its on_complete runs while the body is still the wire string;
      # {Provider::HTTP::Connection::MiddlewareStack} places it there.
      class WalResponseTee < Faraday::Middleware
        def call(env)
          @app.call(env).on_complete do
            frame = env.request.context && env.request.context[:wal_frame]
            frame.append(env.body) if frame && env.body.is_a?(String)
          end
        end
      end
    end
  end
end

Faraday::Response.register_middleware(lain_wal_response_tee: Lain::Provider::AnthropicRaw::WalResponseTee)
