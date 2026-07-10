# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "timeout"
require_relative "error_middleware"
require_relative "logging/sink_logger"
require_relative "connection/middleware_stack"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/connection.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# Leak site 1 (RubyLLM.logger, lines 17/89/90): the Faraday `:logger`
# middleware is now built from an injected `Lain::Sink` via
# {Logging::SinkLogger}, defaulting to `Sink::Null`, instead of a global
# `::Logger` writing to $stdout.
#
# Leak site 3 (RubyLLM.instrument, line 76): the seam is kept -- every
# request still gets wrapped so something can observe method/url/status --
# but the default is a no-op that just yields. Wiring it to
# `ActiveSupport::Notifications` is the `journal` branch's job.
#
# Leak site 4 (RubyLLM.configure, line 150): that text lives inside a
# heredoc in `ensure_configured!`, not a call; only the message changed.
#
# Also dropped, per the porting brief: `require "faraday/multipart"` and the
# `faraday.request :multipart` line. The Files API is unused and
# `faraday-multipart` is not a dependency.
#
# Faraday middleware assembly (timeout/logging/retry/JSON/errors/proxy) moved
# to {MiddlewareStack} -- a real, separate responsibility from the
# request/response API this class exposes -- to clear the default
# `Metrics/ClassLength` without loosening it. See middleware_stack.rb.

module Lain
  class Provider
    module HTTP
      # One provider's HTTP seam: `#post`/`#get`, each instrumented, over a
      # Faraday::Connection {MiddlewareStack} assembles once at construction
      # (Faraday's builder is `StackLocked` after the first request).
      class Connection
        # The default instrumenter: no journal, no bus, just run the block.
        # `Connection#post`/`#get` always wrap through this, so swapping in a
        # real instrumenter later touches one constructor argument, not every
        # call site.
        NULL_INSTRUMENTER = ->(_name, _payload, &block) { block.call }

        attr_reader :provider, :connection, :config

        # A bare Faraday connection with only logging + raise_error, for
        # requests that do not go through a Provider (kept for parity with
        # the vendored source; nothing in this slice calls it yet).
        def self.basic(sink: Sink::Null.new, &block)
          Faraday.new do |f|
            f.response :logger,
                       Logging::SinkLogger.new(sink: sink),
                       bodies: false,
                       errors: true,
                       headers: false,
                       log_level: :debug
            f.response :raise_error
            yield f if block_given?
          end
        end

        # @param sink [Lain::Sink] where log lines go; default sends them nowhere
        # @param instrumenter [#call] `#call(name, payload) { }`; default is a no-op
        # @param log_level [Symbol] :debug also logs request/response bodies
        def initialize(provider, config, sink: Sink::Null.new, instrumenter: NULL_INSTRUMENTER, log_level: :info)
          @provider = provider
          @config = config
          @sink = sink
          @instrumenter = instrumenter
          ensure_configured!
          @connection ||= MiddlewareStack.new(provider, config, sink:, log_level:).build
        end

        def post(url, payload, &block)
          instrument_request(:post, url) do
            @connection.post url, payload do |req|
              req.headers.merge! provider_headers
              yield req if block_given?
            end
          end
        end

        def get(url, &block)
          instrument_request(:get, url) do
            @connection.get url do |req|
              req.headers.merge! provider_headers
              yield req if block_given?
            end
          end
        end

        def instance_variables
          super - %i[@config @connection]
        end

        private

        def provider_headers
          @provider.respond_to?(:headers) ? @provider.headers : {}
        end

        def instrument_request(method, url)
          payload = {
            provider: @provider.respond_to?(:slug) ? @provider.slug : @provider.class.name,
            method: method,
            url: url
          }

          @instrumenter.call("request.lain_provider_http", payload) do
            response = yield
            payload[:status] = response.status if response.respond_to?(:status)
            response
          end
        end

        def ensure_configured!
          return if @provider.configured?

          missing = @provider.configuration_requirements.reject { |req| @config.send(req) }
          config_block = <<~RUBY
            Lain::Provider::HTTP::Configuration.new.tap do |config|
              #{missing.map { |key| "config.#{key} = ENV['#{key.to_s.upcase}']" }.join("\n  ")}
            end
          RUBY

          raise ConfigurationError,
                "#{@provider.name} provider is not configured. Add this to your initialization:\n\n#{config_block}"
        end
      end
    end
  end
end
