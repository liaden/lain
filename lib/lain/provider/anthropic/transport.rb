# frozen_string_literal: true

require "faraday"

module Lain
  class Provider
    class Anthropic < Provider
      # A thin subclass of the vendored Anthropic HTTP provider, REUSING its
      # Faraday stack and SSE engine.
      #
      # It deliberately does NOT go through the vendored
      # `complete`/`stream_response`: that path builds and consumes the lossy
      # `Message`, folding the stream through the flattening
      # `StreamAccumulator`. Here the payload is already rendered by
      # {AnthropicEncoding} and each parsed SSE event is handed straight out, so
      # the block-preserving {StreamAssembler} does the reassembly.
      #
      # == Spooling raw bytes to the WAL
      #
      # The Provider owns the frame -- it computed the request digest the frame
      # is keyed by -- and the transport only appends what it sees off the wire.
      # The two paths reach those bytes differently: streaming tees every raw
      # `on_data` chunk before the SSE parser touches it, while the sync path
      # cannot use `on_data` (it nils the parsed body the error middleware still
      # needs) and so rides {WalResponseTee}.
      class Transport < Provider::HTTP::Providers::Anthropic
        # One non-streaming round trip. `faraday.response :json` has already parsed
        # the body, so `#body` is a Hash; {WalResponseTee} captured the wire bytes
        # for `frame` earlier in the same response, before that parse.
        def sync_post(payload, headers = {}, frame: Spool::Null::Frame.new,
                      witness: ErrorWrapping::WireWitness::Unwitnessed)
          response = connection.post(completion_url, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            req.options.context = (req.options.context || {}).merge(wal_frame: frame, wire_witness: witness)
          end
          frame.close(complete: true)
          response
        end

        # It posts through the vendored {Streaming#post_stream} rather than
        # `connection.post` directly, because that is what performs the
        # end-of-stream flush -- without it an `event: error` the server never
        # terminated stays in the SSE parser and the overload is handed back as
        # an empty, apparently successful turn. `flush:` is the UNTEED handler:
        # the flush's blank line is ours, so it must not reach the WAL frame,
        # which records only what came off the wire.
        def stream(payload, headers = {}, frame: Spool::Null::Frame.new,
                   witness: ErrorWrapping::WireWitness::Unwitnessed, &on_event)
          handler = sse_handler(&on_event)
          post_stream(connection, stream_url, payload, tee_chunks(handler, frame), flush: handler) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            # On the context so RetryTap#retry_block reaches THIS request's frame
            # and witness off the retried env, exactly as the sync path does.
            req.options.context = (req.options.context || {}).merge(wal_frame: frame, wire_witness: witness)
          end
          frame.close(complete: true)
        end

        private

        def sse_handler(&on_event)
          build_on_data_handler { |data| yield data if data.is_a?(Hash) }
        end

        # The verbatim wire chunk reaches the WAL BEFORE it is parsed; the splat
        # forwards the rest of `on_data`'s arguments untouched.
        def tee_chunks(handler, frame)
          proc do |chunk, *rest|
            frame.append(chunk)
            handler.call(chunk, *rest)
          end
        end

        # {ErrorHandling#build_stream_error_response} prefers `status` -- the
        # SEVERITY GUESS `parse_streaming_error` derives from the error body's
        # shape (500, or 529 for "overloaded_error") -- over `env&.status`. That
        # guess exists for an in-stream SSE `event: error`, where the response
        # already returned 200 and no real status is available. But on a
        # response FaradayHandlers#v2_on_data has already classified as FAILED
        # (status != 200, known from the headers before any body byte streams
        # in), the real status is sitting right there and is authoritative --
        # yet the guess still won every time, so a genuine 400 got relabeled
        # ServerError (500), which IS in the retry allowlist, and faraday-retry
        # retried a request the sync path never would. `env&.status` is
        # 200 for exactly the SSE-event case the guess is for, so overriding
        # `status` only when a real non-2xx status is already known leaves that
        # case untouched and forwards the rest to the shared implementation.
        def build_stream_error_response(parsed_data, env, status)
          known_status = env&.status
          failed_status = known_status if known_status && !(200..299).cover?(known_status)
          super(parsed_data, env, failed_status || status)
        end
      end

      # Copies `env.body` BEFORE the JSON middleware parses it into the WAL
      # frame carried on the request context. A no-op unless a frame is present.
      # It MUST sit below `response :json` so its on_complete runs while the
      # body is still the wire string; {Provider::HTTP::Connection::MiddlewareStack}
      # places it there.
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

Faraday::Response.register_middleware(lain_wal_response_tee: Lain::Provider::Anthropic::WalResponseTee)
