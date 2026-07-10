# frozen_string_literal: true

require "event_stream_parser"
require "faraday"
require "json"
require_relative "stream_accumulator"
require_relative "streaming/error_handling"
require_relative "streaming/faraday_handlers"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/streaming.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# This is the base SSE engine -- the provider-generic half of streaming,
# NOT under `providers/`. It drives Faraday's `on_data` callback, feeds the
# bytes through `EventStreamParser`, and calls the three universal hooks
# every provider supplies: `stream_url`, `build_chunk(data)`,
# `parse_streaming_error(data)`. It is `include`d into the base `Provider`,
# so `self` inside every method here is a provider instance; a provider that
# defines no `streaming.rb` of its own still streams, using the generic
# `parse_streaming_error` in {ErrorHandling} (`Anthropic::Streaming`
# overrides it, and is included at the subclass level so its version wins for
# Anthropic).
#
# Streaming *error* handling is a real, separate responsibility (a successful
# stream never touches it) and lives in {ErrorHandling}, composed in via
# `include` because those methods must dispatch `parse_streaming_error` and
# `ErrorMiddleware.parse_error(provider: self)` back through the provider.
# The Faraday-version `on_data` adapter is {FaradayHandlers}. Both extractions
# keep this module under the default `Metrics/ModuleLength` without loosening
# the cop.
#
# Leak sites 1/2 resolved the same way as everywhere else in this slice:
# every `RubyLLM.logger.debug { }` (guarded upstream by
# `RubyLLM.config.log_stream_debug` in one spot, unguarded in others) becomes
# `stream_debug { }`, which writes to the provider's injected `@sink` and is
# gated by the injected `@stream_debug` flag. `Sink::Null` + `false` is the
# default, so the trace is silent unless asked for -- the several upstream
# call sites that were unguarded only ever emitted when the global logger's
# level was already DEBUG, which was never the case by default.

module Lain
  class Provider
    module HTTP
      # Base streaming engine; see the file header.
      module Streaming
        include ErrorHandling

        module_function

        def stream_response(connection, payload, additional_headers = {}, &block)
          accumulator = StreamAccumulator.new(sink: @sink, debug: @stream_debug)

          response = connection.post stream_url, payload do |req|
            req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
            assign_on_data(req, accumulator, &block)
          end

          message = accumulator.to_message(response)
          stream_debug { "Stream completed: #{message.content}" }
          message
        end

        def handle_stream(&block)
          build_on_data_handler do |data|
            block.call(build_chunk(data)) if data.is_a?(Hash)
          end
        end

        private

        # Writes a streaming-debug line to the injected sink, gated by the
        # injected debug flag. Replaces upstream's `RubyLLM.logger.debug { }`.
        def stream_debug
          @sink.puts(yield) if @stream_debug
        end

        def assign_on_data(req, accumulator, &block)
          handler = handle_stream do |chunk|
            accumulator.add chunk
            block.call chunk
          end

          if faraday_1?
            req.options[:on_data] = handler
          else
            req.options.on_data = handler
          end
        end

        def faraday_1?
          Faraday::VERSION.start_with?("1")
        end

        def build_on_data_handler(&handler)
          buffer = +""
          parser = EventStreamParser::Parser.new

          FaradayHandlers.build(
            faraday_v1: faraday_1?,
            on_chunk: ->(chunk, env) { process_stream_chunk(chunk, parser, env, &handler) },
            on_failed_response: ->(chunk, env) { handle_failed_response(chunk, buffer, env) }
          )
        end

        def process_stream_chunk(chunk, parser, env, &block)
          stream_debug { "Received chunk: #{chunk}" }

          if error_chunk?(chunk)
            handle_error_chunk(chunk, env)
          elsif json_error_payload?(chunk)
            handle_json_error_chunk(chunk, env)
          else
            yield handle_sse(chunk, parser, env, &block)
          end
        end

        def handle_sse(chunk, parser, env, &block)
          parser.feed(chunk) do |type, data|
            case type.to_sym
            when :error
              handle_error_event(data, env)
            else
              yield handle_data(data, env, &block) unless data == "[DONE]"
            end
          end
        end

        def handle_data(data, env)
          parsed = JSON.parse(data)
          return parsed unless parsed.is_a?(Hash) && parsed.key?("error")

          handle_parsed_error(parsed, env)
        rescue JSON::ParserError => e
          stream_debug { "Failed to parse data chunk: #{e.message}" }
        end
      end
    end
  end
end
