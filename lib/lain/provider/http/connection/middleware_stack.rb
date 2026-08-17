# frozen_string_literal: true

# New code, not a port. Upstream's `Connection` (159 lines) folds Faraday
# middleware assembly (timeout, logging, retry, JSON, error-mapping, proxy)
# directly into itself, which pushed the class past this project's default
# `Metrics/ClassLength` (100) with no `Metrics/*` loosening allowed. Building
# the Faraday stack is a real, separate responsibility from the request/
# response API `Connection#post`/`#get` expose, so it is extracted rather
# than disabled away. Every `setup_*` method and `retry_exceptions` are
# unchanged from `connection.rb`'s original, apart from namespace and the
# leak-site-1 Sink routing that lived here already.

module Lain
  class Provider
    module HTTP
      class Connection
        # Assembles one Faraday::Connection for a provider: timeout, logging
        # (leak site 1 -- an injected Sink, never a global Logger), retry,
        # JSON (de)serialization, error-mapping, and an optional HTTP proxy.
        # Built once -- Faraday's builder is `StackLocked` after the first
        # request -- by {Connection#initialize}.
        class MiddlewareStack
          # Gives one request's {Streaming::StallClock} its LIFETIME, which is
          # the half of stalled-stream protection that is knowable here.
          #
          # The other half is not: a middleware never sees a body chunk, so it
          # cannot tell silence from work, and the `on_data` handler that does
          # see them gets no end-of-stream signal to stop a clock with. So the
          # split falls exactly there -- this owns the scope, the handler owns
          # the ticks, and the clock arms itself on the first byte so that a
          # long prompt evaluation is still bounded only by `request_timeout`.
          class StallProtection < Faraday::Middleware
            def call(env)
              Streaming::StallClock.watching(options[:grace]) { @app.call(env) }
            end
          end

          def initialize(provider, config, sink:, log_level:)
            @provider = provider
            @config = config
            @sink = sink
            @log_level = log_level
          end

          def build
            Faraday.new(@provider.api_base) do |faraday|
              setup_timeout(faraday)
              setup_logging(faraday)
              setup_retry(faraday)
              setup_stall_protection(faraday)
              setup_middleware(faraday)
              setup_http_proxy(faraday)
            end
          end

          private

          def setup_timeout(faraday)
            faraday.options.timeout = @config.request_timeout
          end

          def setup_logging(faraday)
            logger = Logging::SinkLogger.new(sink: @sink, level: @log_level)
            faraday.response :logger,
                             logger,
                             bodies: logger.debug?,
                             errors: true,
                             headers: false,
                             log_level: :debug do |formatter|
              formatter.filter(logging_regexp("[A-Za-z0-9+/=]{100,}"), "[BASE64 DATA]")
              formatter.filter(logging_regexp("[-\\d.e,\\s]{100,}"), "[EMBEDDINGS ARRAY]")
            end
          end

          def logging_regexp(pattern)
            return Regexp.new(pattern) if @config.log_regexp_timeout.nil? || !Regexp.respond_to?(:timeout)

            Regexp.new(pattern, timeout: @config.log_regexp_timeout)
          end

          def setup_retry(faraday)
            faraday.request :retry, retry_options
          end

          # Registered AFTER the retry middleware, so it sits inside it and each
          # attempt is clocked from its own first byte rather than the run's.
          # The error it raises is deliberately absent from {#retry_exceptions}
          # -- see {Streaming::StalledStreamError} for what a retryable one
          # would have cost.
          def setup_stall_protection(faraday)
            return if stall_grace.nil?

            faraday.use StallProtection, grace: stall_grace
          end

          # `respond_to?` for the same reason `setup_middleware` asks it of
          # `faraday_adapter`: a Configuration-alike handed in by a caller
          # outside this slice should not have to know the option exists.
          def stall_grace
            @config.respond_to?(:stream_stall_timeout) ? @config.stream_stall_timeout : nil
          end

          def retry_options
            {
              max: @config.max_retries,
              interval: @config.retry_interval,
              interval_randomness: @config.retry_interval_randomness,
              backoff_factor: @config.retry_backoff_factor,
              methods: Faraday::Retry::Middleware::IDEMPOTENT_METHODS + [:post],
              exceptions: retry_exceptions
            }.merge(retry_callbacks)
          end

          # Only the callbacks a provider actually set; nils are dropped so
          # faraday-retry falls back to its own defaults (a bare `proc {}` for the
          # blocks, `RateLimit-Reset` for the header) rather than being disabled.
          def retry_callbacks
            {
              retry_block: @config.retry_block,
              exhausted_retries_block: @config.exhausted_retries_block,
              rate_limit_reset_header: @config.rate_limit_reset_header,
              header_parser_block: @config.header_parser_block
            }.compact
          end

          def setup_middleware(faraday)
            faraday.request :json
            faraday.response :json
            # BELOW :json so its on_complete sees the wire body before the parse;
            # a strict no-op unless a request carries a WAL frame on its context
            # (see Anthropic::WalResponseTee), so every other request is
            # untouched. Registered by that provider's transport at load.
            faraday.response :lain_wal_response_tee
            adapter = @config.respond_to?(:faraday_adapter) ? @config.faraday_adapter : :net_http
            faraday.adapter(adapter || :net_http)
            faraday.use :lain_provider_http_errors, provider: @provider
          end

          def setup_http_proxy(faraday)
            return unless @config.http_proxy

            faraday.proxy = @config.http_proxy
          end

          def retry_exceptions
            [
              Errno::ETIMEDOUT, Timeout::Error, Faraday::TimeoutError, Faraday::ConnectionFailed,
              Faraday::RetriableResponse, RateLimitError, ServerError, ServiceUnavailableError, OverloadedError
            ]
          end
        end
      end
    end
  end
end
