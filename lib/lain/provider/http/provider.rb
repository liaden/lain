# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # Base class for the vendored HTTP providers: the Faraday connection, the
      # SSE engine and the wire configuration a transport builds on.
      #
      # Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/provider.rb.
      # Changed: RubyLLM:: -> Lain::Provider::HTTP::.
      #
      # Error-body parsing moved to {ErrorBody} -- a real, separate
      # responsibility -- to clear the default `Metrics/ClassLength` without
      # loosening it. Lain drives the round trip itself through
      # `Provider::Anthropic::Transport`, so the upstream `complete` seam is not here.
      class Provider
        include Streaming

        attr_reader :config, :connection

        # @param config [Provider::HTTP::Configuration] the vendor-specific settings (api key/base,
        #   retry knobs, `log_stream_debug`); read here for the stream-debug flag and
        #   `configured?`, then forwarded unmodified to a constructed {Connection}
        # @param connection [Connection, nil] injected whole in specs
        # @param sink [Lain::Sink] where streaming debug lines go, and forwarded
        #   to a constructed Connection; ignored for logging when `connection:`
        #   is given directly
        # @param instrumenter [#call] forwarded to a constructed Connection
        # @param log_level [Symbol] forwarded to a constructed Connection
        def initialize(config, connection: nil, sink: Sink::Null.new, instrumenter: Connection::NULL_INSTRUMENTER,
                       log_level: :info)
          @config = config
          @sink = sink
          # Reads OUR Configuration, not a global singleton (leak site 2's shape):
          # the `Streaming` debug trace is off unless asked for.
          @stream_debug = config.respond_to?(:log_stream_debug) && config.log_stream_debug ? true : false
          ensure_configured!
          @connection = connection || Connection.new(self, @config, sink:, instrumenter:, log_level:)
        end

        def api_base
          raise NotImplementedError
        end

        def headers
          {}
        end

        def slug
          self.class.slug
        end

        def name
          self.class.name
        end

        def configuration_requirements
          self.class.configuration_requirements
        end

        def configured?
          configuration_requirements.all? { |req| @config.send(req) }
        end

        def local?
          self.class.local?
        end

        def remote?
          self.class.remote?
        end

        def parse_error(response)
          ErrorBody.parse(response)
        end

        class << self
          def name
            to_s.split("::").last
          end

          def slug
            name.downcase
          end

          def configuration_requirements
            []
          end

          def configuration_options
            []
          end

          def local?
            false
          end

          def remote?
            !local?
          end

          def configured?(config)
            configuration_requirements.all? { |req| config.send(req) }
          end
        end

        private

        def ensure_configured!
          missing = configuration_requirements.reject { |req| @config.send(req) }
          return if missing.empty?

          raise ConfigurationError,
                "Missing configuration for #{name}: #{missing.join(", ")}. " \
                "Set these keys before using this provider."
        end
      end
    end
  end
end
