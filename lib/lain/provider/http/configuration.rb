# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/configuration.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::. Dropped every option this
# vendored slice has no code left to serve: `default_*_model`,
# `model_registry_file`, `model_registry_class`, `model_registry_source`,
# `use_new_acts_as` (Models registry, not vendored -- leak sites 6/8), the
# moderation/image/transcription options (leak site 10, out of scope), and
# `logger`/`instrumenter`/`log_file`/`log_level`/`deprecation_behavior`/
# `tool_concurrency` (the global-Logger and ActiveSupport::Notifications
# seams this slice replaces with injected `Sink`/instrumenter arguments --
# see connection.rb and Logging::SinkLogger -- so there is nothing left for
# a Configuration *option* to point at). `register_provider_options` and the
# dynamic `option` DSL are kept exactly: they are what lets a future
# provider (openai, gemini, ...) register `<slug>_api_key` /
# `<slug>_api_base` without this class knowing their names in advance.
#
# The custom `log_regexp_timeout=` setter upstream warned via `RubyLLM.logger`
# on Ruby versions predating `Regexp.timeout=` -- an unlisted twelfth leak
# site, since it is dead code on the ruby-4.0.5 this project pins (Regexp has
# supported `.timeout=` since 3.2) and would otherwise be the one call in this
# file that reaches a global logger. Dropped in favor of the plain generated
# setter.

module Lain
  class Provider
    module HTTP
      # Dynamic, provider-extensible configuration for the HTTP transport.
      class Configuration
        class << self
          # Declare a single configuration option.
          def option(key, default = nil)
            key = key.to_sym
            return if options.include?(key)

            attr_reader key

            define_method("#{key}=") do |value|
              value = nil if value.is_a?(String) && value.strip.empty?
              instance_variable_set(:"@#{key}", value)
            end

            option_keys << key
            defaults[key] = default
          end

          # Lets a provider register its own `<slug>_api_key` / `<slug>_api_base`
          # (and anything else it needs) without this class enumerating providers.
          def register_provider_options(options)
            Array(options).each { |key| option(key, nil) }
          end

          def options
            option_keys.dup
          end

          private

          def option_keys = @option_keys ||= []
          def defaults = @defaults ||= {}
          private :option
        end

        option :request_timeout, 300
        option :max_retries, 3
        option :retry_interval, 0.1
        option :retry_backoff_factor, 2
        option :retry_interval_randomness, 0.5
        option :http_proxy, nil
        option :faraday_adapter, :net_http
        # faraday-retry callbacks and rate-limit knobs. Left nil so the vendored
        # default retry stays silent; a provider that wants retries JOURNALED
        # (see Provider::AnthropicRaw) sets these, and MiddlewareStack forwards
        # them so the retry becomes visible instead of invisible spend.
        option :retry_block, nil
        option :exhausted_retries_block, nil
        option :rate_limit_reset_header, nil
        option :header_parser_block, nil
        option :log_stream_debug, -> { ENV["LAIN_STREAM_DEBUG"] == "true" }
        option :log_regexp_timeout, -> { Regexp.respond_to?(:timeout) ? (Regexp.timeout || 1.0) : nil }

        def initialize
          self.class.send(:defaults).each do |key, default|
            value = default.respond_to?(:call) ? instance_exec(&default) : default
            public_send("#{key}=", value)
          end
        end

        # Redacted `#inspect`/`#pretty_print` support: never echo a key, secret,
        # or token back into a log line or a crashed spec's failure output.
        def instance_variables
          super.reject { |ivar| ivar.to_s.match?(/_id|_key|_secret|_token$/) }
        end
      end
    end
  end
end
