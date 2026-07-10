# frozen_string_literal: true

require_relative "configuration"
require_relative "connection"
require_relative "error"
require_relative "provider/error_body"
require_relative "provider/registry"
require_relative "streaming"
require_relative "utils"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/provider.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# Leak site 5 (provider.rb:193 -- Configuration.register_provider_options):
# KEPT. This is what lets a future provider (openai, gemini, ...) register
# its own `<slug>_api_key` / `<slug>_api_base` without Configuration
# enumerating providers up front. Moved into {Registry}; see that file.
#
# Leak site 6 (provider.rb:201 -- Models.find(model) inside .for): `.for`
# is deleted outright. We have no model registry, so "resolve a provider by
# model id" has nothing to look the model up in; `.resolve` (by provider
# name) is what every caller in this slice actually uses.
#
# Leak site 10 (provider.rb:235,240 -- UnsupportedAttachmentError, require
# "marcel"): `validate_paint_inputs!` and `build_audio_file_part` are gone.
# `#paint`/`#transcribe`/`#embed`/`#moderate`/`#list_models` went with them --
# each called at least one rendering/parsing method only ever defined by
# Anthropic::Media, Anthropic::Embeddings, or Anthropic::Models (leak site
# 7), none of which are vendored, so keeping the public methods around would
# have meant keeping dead code that raises NoMethodError the moment anything
# calls it. `#complete` -- "the stateless #complete seam," per the porting
# plan -- is the one API this slice exists to serve.
#
# `include Streaming` mixes in the base SSE engine (streaming.rb), whose
# `stream_response` is what `#complete(&block)` calls. It needs the
# `event_stream_parser` gem (added to the gemspec for exactly this).
# `Anthropic::Streaming` (providers/anthropic/streaming.rb) is included at
# the subclass level and supplies the Anthropic-specific `build_chunk` /
# `stream_url` / `parse_streaming_error` hooks the base engine calls; when a
# provider defines no streaming.rb of its own, the base engine still works
# with whatever hooks the base supplies.
#
# The class-level registry (`providers`/`register`/`resolve`) and error-body
# parsing moved to {Registry}/{ErrorBody} -- each a real, separate
# responsibility -- to clear the default `Metrics/ClassLength` without
# loosening it.

module Lain
  class Provider
    module HTTP
      # Base class for the vendored HTTP providers. One round trip via
      # {#complete}; never a loop.
      class Provider
        extend Registry
        include Streaming

        attr_reader :config, :connection

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
          # the `Streaming`/`StreamAccumulator` debug trace is off unless asked for.
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

        # One round trip: encode `messages`/`tools` into the provider's wire
        # payload and either stream (block given, via the mixed-in Streaming
        # engine) or return a completed {Message}.
        def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil,
                     tool_prefs: nil, &block)
          payload = Utils.deep_merge(render_payload_for(messages, tools:, temperature:, model:, stream: !block.nil?,
                                                                  schema:, thinking:, tool_prefs:), params)

          block ? stream_response(@connection, payload, headers, &block) : sync_response(@connection, payload, headers)
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

        def format_messages(messages)
          messages.map { |msg| { role: msg.role.to_s, content: msg.content } }
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

        def render_payload_for(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:)
          render_payload(messages, tools:, tool_prefs:,
                                   temperature: maybe_normalize_temperature(temperature, model),
                                   model:, stream:, schema:, thinking:)
        end

        def ensure_configured!
          missing = configuration_requirements.reject { |req| @config.send(req) }
          return if missing.empty?

          raise ConfigurationError,
                "Missing configuration for #{name}: #{missing.join(", ")}. " \
                "Set these keys before using this provider."
        end

        def maybe_normalize_temperature(temperature, _model)
          temperature
        end

        def sync_response(connection, payload, additional_headers = {})
          response = connection.post completion_url, payload do |req|
            req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
          end
          parse_completion_response response
        end
      end
    end
  end
end
