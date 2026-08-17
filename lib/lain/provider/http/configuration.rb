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
# site, since it is dead code on the ruby-4.0.6 floor this project requires
# (Regexp has supported `.timeout=` since 3.2) and would otherwise be the one
# call in this file that reaches a global logger. Dropped in favor of the
# plain generated setter.

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
          #
          # The parameter is a list of option NAMES, not an options hash --
          # `Array()` is there so a provider declaring a single one may pass it
          # bare. Saying that in the type is also what stands `yard-lint`'s
          # `Tags/OptionTags` down: it keys on the parameter's NAME, and per-key
          # `option` tags would be the wrong instrument for a list of keys.
          #
          # @param options [Array<Symbol>, Symbol] the option keys to declare
          # @return [void] the keys back, which no caller reads
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
        # The INTER-CHUNK grace: the longest silence tolerated between body
        # chunks once a stream has started emitting. nil disables the check.
        #
        # A separate number from `request_timeout` because the two measure
        # different things, and conflating them is what made a stalled ollama
        # wait over 400 seconds printing nothing. `request_timeout` is
        # per-read, so it also bounds the wait for the FIRST byte -- which on
        # a local arm is prompt evaluation, legitimately minutes of silence
        # (provider/ollama.rb: "a local model that thinks for six minutes is a
        # real shape"), and is why 300 stands here untouched. Once tokens are
        # flowing, a 30s gap from a token-streaming server means the stream is
        # dead rather than slow. AWS's stalled-stream detector uses a 5s grace,
        # which is right for bulk transfer and far too tight for generation.
        #
        # `LAIN_STREAM_STALL_TIMEOUT` is the off switch an operator can reach --
        # nothing else constructs a Configuration outside `lib/`, and unlike
        # `request_timeout` (which only fires when the server never answered)
        # this knob can end a WORKING generation, so it needs one. `=0` disables;
        # a positive number sets the grace. Same shape as `log_stream_debug`
        # below, which is this file's pattern for a knob with no CLI flag.
        option :stream_stall_timeout, -> { ENV.fetch("LAIN_STREAM_STALL_TIMEOUT", 30) }
        option :max_retries, 3
        option :retry_interval, 0.1
        option :retry_backoff_factor, 2
        option :retry_interval_randomness, 0.5
        option :http_proxy, nil
        option :faraday_adapter, :net_http
        # faraday-retry callbacks and rate-limit knobs. Left nil so the vendored
        # default retry stays silent; a provider that wants retries JOURNALED
        # (see Provider::Anthropic) sets these, and MiddlewareStack forwards
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

        # The one option with a hand-written setter, because BOTH natural
        # operator mistakes are silently catastrophic under the generated one.
        #
        # `0` is the universal "no timeout" idiom -- curl, Faraday's own
        # `timeout`, AWS -- but a zero grace makes `idle > grace` true on the
        # monitor's first sweep, so every stream would die at its first byte.
        # An operator reaching for the OFF switch would get the maximally
        # destructive setting. Non-positive therefore means nil, which is off.
        #
        # And a non-numeric would be accepted here, then raise a bare
        # `ArgumentError` from inside the Faraday stack on the first chunk --
        # where `wrapping_errors` rescues only `HTTP::Error` and
        # `Faraday::Error`, so it would escape every `rescue` in the codebase.
        # That is the exact failure {Streaming::StalledStreamError}'s own
        # ancestry was chosen to avoid, so it is refused here, at the one moment
        # a human is looking at the value. A String that parses is taken (the
        # env var arrives as one); anything else is a mistake, said out loud.
        #
        # A Numeric is kept AS WRITTEN rather than coerced, so the grace the
        # stall message prints is the one the operator set and can grep for.
        def stream_stall_timeout=(value)
          @stream_stall_timeout = stall_seconds(value)
        end

        # Redacted `#inspect`/`#pretty_print` support: never echo a key, secret,
        # or token back into a log line or a crashed spec's failure output.
        def instance_variables
          super.reject { |ivar| ivar.to_s.match?(/(?:_id|_key|_secret|_token)$/) }
        end

        # MRI's pretty_print honors the `instance_variables` override above, but
        # `Object#inspect` walks the ivar table directly and ignores it -- so
        # inspect must render its own view over the filtered list.
        def inspect
          fields = instance_variables.map { |ivar| "#{ivar}=#{instance_variable_get(ivar).inspect}" }
          "#<#{self.class.name} #{fields.join(", ")}>"
        end

        private

        def stall_seconds(value)
          return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

          seconds = value.is_a?(Numeric) ? value : Float(value, exception: false)
          if seconds.nil?
            raise ArgumentError, "stream_stall_timeout wants seconds or nil, got #{value.inspect} " \
                                 "(LAIN_STREAM_STALL_TIMEOUT=0 disables stall protection)"
          end

          seconds.positive? ? seconds : nil
        end
      end
    end
  end
end
