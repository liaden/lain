# frozen_string_literal: true

require "event_stream_parser"
require "faraday"
require "json"
require_relative "streaming/error_handling"
require_relative "streaming/faraday_handlers"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/streaming.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::. Dropped upstream's `event: error`
# fast path (`error_chunk?`/`handle_error_chunk`, in {ErrorHandling}) and added
# an end-of-stream flush ({#flush_stream}). The fast path read
# `chunk.split("\n")[1]` off a RAW `on_data` fragment, so a transport that split
# the event line from the data line made `[1]` nil and the provider raised
# NoMethodError instead of the typed error; `handle_sse`'s `:error` arm reaches
# the same `parse_error_from_json` through a parser that buffers across
# fragments. Deleting the fast path alone would have traded that crash for
# silence, because the parser DISCARDS an event that never got its terminating
# blank line -- so the flush comes with it, and covers every truncated terminal
# event rather than just the error one.
#
# Three methods here are Lain's, not upstream's, and a re-vendor MUST carry them
# forward or it breaks code outside this directory:
#
# * {#post_stream} -- posts a streaming request, assigns the handler, and runs
#   the flush. `Anthropic::Transport#stream` and `Bedrock::Transport#stream`
#   (both outside the vendored slice) post through it precisely so the flush
#   cannot be forgotten; dropping it silently restores the swallow.
# * {#accumulating_handler} -- the handler `stream_response` used to build
#   inline, extracted because the flush needs it after the response completes.
# * `assign_on_data(req, handler)` -- upstream's took `(req, accumulator,
#   &block)` and built the handler itself; it is pure assignment now.
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
          on_data = accumulating_handler(accumulator, &block)
          response = post_stream(connection, stream_url, payload, on_data) do |req|
            req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
          end

          message = accumulator.to_message(response)
          stream_debug { "Stream completed: #{message.content}" }
          message
        end

        def handle_stream(&block)
          build_on_data_handler do |data|
            yield(build_chunk(data)) if data.is_a?(Hash)
          end
        end

        private

        # Writes a streaming-debug line to the injected sink, gated by the
        # injected debug flag. Replaces upstream's `RubyLLM.logger.debug { }`.
        def stream_debug
          @sink.puts(yield) if @stream_debug
        end

        # Built before the request rather than inside the `post` block, because
        # {#flush_stream} needs the same handler -- and so the same parser --
        # after the response is complete.
        def accumulating_handler(accumulator, &block)
          handle_stream do |chunk|
            accumulator.add chunk
            yield chunk
          end
        end

        # Every SSE streaming POST goes through here, so no caller can install a
        # handler and forget the flush -- `Anthropic::Transport` and
        # `Bedrock::Transport` install their own and post their own request, and
        # both silently dropped truncated terminal events until they came
        # through this method. `Ollama::Transport` posts its own and is the one
        # deliberate exception: `application/x-ndjson` has no SSE parser and so
        # no buffered event to flush, and its `StreamAssembler#result` already
        # flushes a trailing line that arrived without its newline. The block
        # configures the request; the handler assignment and the flush are ours.
        #
        # `on_data` is what Faraday gets. `flush` is what the end-of-stream
        # blank line goes through: the same handler, unless a caller wrapped it
        # to record what arrives (Anthropic tees every wire chunk into the WAL),
        # in which case the flush must bypass the wrapper -- that blank line is
        # ours, it never came off the wire.
        #
        # faraday-retry reuses one `on_data` proc across attempts, so a retried
        # stream feeds one parser (pre-existing) and this flush runs once, over
        # whatever the final attempt left buffered.
        def post_stream(connection, url, payload, on_data, flush: on_data)
          response = connection.post url, payload do |req|
            yield req if block_given?
            assign_on_data(req, on_data)
          end

          flush_stream(flush, response)
          response
        end

        # Faraday's `on_data` gets no end-of-stream signal, and the SSE spec has
        # the parser DISCARD an event that never reached its terminating blank
        # line ("if the file ends in the middle of an event, before the final
        # empty line, the incomplete event is not dispatched"). A provider that
        # writes `event: error` and then drops the connection lands exactly
        # there -- and a discarded error event does not surface as an exception,
        # it surfaces as an empty Message recorded as a successful turn. Feeding
        # one blank line through the same handler once the body is read
        # dispatches whatever is still buffered; after a clean stream the
        # parser's data buffer is empty, so the same feed dispatches nothing.
        #
        # One consequence to know: this runs AFTER `connection.post` returns, so
        # an error raised here is raised outside the Faraday stack and never
        # meets `retry_exceptions` (MiddlewareStack) -- a flushed
        # `OverloadedError` surfaces on the first attempt, where the same error
        # dispatched mid-body would have been retried.
        def flush_stream(on_data, response)
          on_data.call("\n\n", 0, response.env)
        end

        def assign_on_data(req, handler)
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

        # A raw JSON error body is not an event stream, so it never reaches the
        # parser and keeps its own branch. Everything else -- `event: error`
        # included -- goes through `handle_sse`, whose parser is what survives a
        # fragment boundary. What it does not survive is truncation: an event
        # that never gets its terminating blank line stays in the parser's
        # buffer, and dispatching that one is {#flush_stream}'s job.
        def process_stream_chunk(chunk, parser, env, &block)
          stream_debug { "Received chunk: #{chunk}" }

          if json_error_payload?(chunk)
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
