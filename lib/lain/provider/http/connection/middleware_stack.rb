# frozen_string_literal: true

# New code, not a port. Upstream folds Faraday middleware assembly into
# `Connection` itself, which pushes that class past the default
# `Metrics/ClassLength` with no loosening allowed -- and building the stack is a
# real, separate responsibility from the request/response API `Connection#post`
# exposes. Every `setup_*` method and `retry_exceptions` are otherwise unchanged
# from upstream, apart from namespace and the Sink routing.

module Lain
  class Provider
    module HTTP
      class Connection
        # Assembles one Faraday::Connection for a provider, logging through an
        # injected Sink rather than a global Logger. Built ONCE, because
        # Faraday's builder is `StackLocked` after the first request.
        class MiddlewareStack
          # Gives one request's {Streaming::StallClock} its LIFETIME, the half
          # of stalled-stream protection knowable here. The other half is not: a
          # middleware never sees a body chunk, so it cannot tell silence from
          # work, and the `on_data` handler that does see them gets no
          # end-of-stream signal to stop a clock with.
          #
          # `env` is PASSED rather than merely wrapped, and that is what joins
          # the two halves: the clock parks itself on `env.request.context`, and
          # `Faraday::Env#stream_response` hands the very same env to `on_data`
          # with every chunk -- so the handler finds this request's clock with
          # nothing ambient shared.
          class StallProtection < Faraday::Middleware
            def call(env)
              Streaming::StallClock.watching(options[:grace], env) { @app.call(env) }
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
            budget = connect_budget
            faraday.options.open_timeout = budget unless budget.nil?
          end

          # `Faraday::Adapter#request_timeout` reads `options[:open_timeout] ||
          # options[:timeout]`, so setting only the one above is what let an
          # address that swallows the SYN hold `connect()` for the whole
          # `request_timeout` -- four times, since `:post` is in
          # `retry_options[:methods]` and `Faraday::ConnectionFailed` is in
          # {#retry_exceptions}. Writing the number explicitly is the whole fix;
          # leaving it nil restores the derivation, which is the off switch.
          #
          # Capped at `request_timeout` because a caller that shortens the whole
          # round trip means it: {Provider::Ollama::Transport}'s `/api/ps` probe
          # asks for 2s on the render path, and a 5s connect budget would hand
          # back the wait that budget exists to avoid.
          #
          # One stance about what a config must answer: the VENDORED options
          # are ASSUMED, while an option this slice added AFTER vendoring is
          # asked for, because a Configuration-alike handed in from outside
          # cannot be expected to have grown it. Not theatre -- drop the
          # `respond_to?` and an existing Configuration double dies on an
          # unexpected `:connect_timeout`.
          def connect_budget
            budget = @config.respond_to?(:connect_timeout) ? @config.connect_timeout : nil
            return nil if budget.nil?

            [budget, @config.request_timeout].min
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
