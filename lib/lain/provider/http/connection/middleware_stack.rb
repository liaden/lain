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
