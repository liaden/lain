# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/configuration.rb.
# Dropped every option this slice has no code left to serve: the model-registry
# ones, the moderation/image/transcription ones, and the
# logger/instrumenter/log-level family, whose global-Logger and
# ActiveSupport::Notifications seams this slice replaces with injected
# `Sink`/instrumenter arguments -- leaving nothing for a Configuration *option*
# to point at.
#
# `register_provider_options` and the dynamic `option` DSL are kept exactly:
# they are what lets a future provider register `<slug>_api_key` /
# `<slug>_api_base` without this class knowing the names in advance.
#
# Upstream's custom `log_regexp_timeout=` setter warned through the global
# logger on Ruby versions predating `Regexp.timeout=`. Dead code on the 4.0.6
# floor this project requires, and otherwise the one call in this file reaching
# a global logger, so it is the plain generated setter here.

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
          # `Tags/OptionTags` down, since it keys on the parameter's name.
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
        # The budget for GETTING CONNECTED, not for the round trip. Separate from
        # `request_timeout` because Faraday derives `open_timeout` from `timeout`
        # when only one is set, so a single knob priced "nothing answered the
        # SYN" the same as "the server is still thinking": 300s per attempt, four
        # attempts deep, and the stall clock cannot shorten it because it arms on
        # a first body chunk that never comes.
        #
        # Read the scope precisely. This bounds the case where the connection
        # never OPENS. A server that ACCEPTS and then sends nothing still costs
        # 4 x `request_timeout`, deliberately: pre-first-byte silence is a local
        # model evaluating a prompt.
        #
        # Nor is it only the SYN. `Net::HTTP` spends `@open_timeout` on the TCP
        # connect, on a direct TLS handshake, and again on a proxied CONNECT
        # tunnel's handshake -- so it bounds each separately, and an
        # HTTPS-through-proxy attempt can spend it twice.
        #
        # Five seconds is two orders of magnitude under the completion budget and
        # an order above the worst plausible handshake: sub-millisecond on
        # loopback, one RTT plus TLS to a hosted arm, and Linux's first two SYN
        # retransmits land at 1s and 4s, inside one attempt. It sits above
        # {Ollama::Transport::PROBE_TIMEOUT_SECONDS} by the same argument.
        #
        # `LAIN_CONNECT_TIMEOUT=0` restores the old behaviour exactly: no
        # separate number, so Faraday derives one again.
        option :connect_timeout, -> { ENV.fetch("LAIN_CONNECT_TIMEOUT", 5) }
        # The INTER-CHUNK grace: the longest silence tolerated between body
        # chunks once a stream has started emitting. nil disables the check.
        #
        # Separate from `request_timeout` because the two measure different
        # things, and conflating them is what made a stalled ollama wait over 400
        # seconds printing nothing. `request_timeout` is per-read, so it also
        # bounds the wait for the FIRST byte -- which on a local arm is prompt
        # evaluation, legitimately minutes of silence, and is why 300 stands
        # untouched. Once tokens are flowing, a 30s gap from a token-streaming
        # server means the stream is dead rather than slow. AWS's stalled-stream
        # detector uses 5s, right for bulk transfer and far too tight for
        # generation.
        #
        # Unlike `request_timeout`, which fires only when the server never
        # answered, this knob can end a WORKING generation -- so it needs an off
        # switch an operator can reach, and `=0` is it.
        option :stream_stall_timeout, -> { ENV.fetch("LAIN_STREAM_STALL_TIMEOUT", 30) }
        option :max_retries, 3
        option :retry_interval, 0.1
        option :retry_backoff_factor, 2
        option :retry_interval_randomness, 0.5
        option :http_proxy, nil
        option :faraday_adapter, :net_http
        # Left nil so the vendored default retry stays silent; a provider that
        # wants retries JOURNALED sets these, and MiddlewareStack forwards them
        # so the retry becomes visible rather than invisible spend.
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

        # Hand-written because BOTH natural operator mistakes are silently
        # catastrophic under the generated setter.
        #
        # `0` is the universal "no timeout" idiom, but a zero grace makes
        # `idle > grace` true on the monitor's first sweep, so every stream would
        # die at its first byte -- an operator reaching for the OFF switch would
        # get the maximally destructive setting. Non-positive therefore means
        # nil, which is off.
        #
        # A non-numeric would be accepted here and then raise a bare
        # `ArgumentError` from inside the Faraday stack on the first chunk, where
        # `wrapping_errors` rescues only `HTTP::Error` and `Faraday::Error` -- so
        # it would escape every `rescue` in the codebase. Refused here instead,
        # at the one moment a human is looking at the value.
        #
        # A Numeric is kept AS WRITTEN rather than coerced, so the grace the
        # stall message prints is the one the operator set and can grep for.
        def stream_stall_timeout=(value)
          @stream_stall_timeout = positive_seconds(value, "stream_stall_timeout",
                                                   "LAIN_STREAM_STALL_TIMEOUT=0 disables stall protection")
        end

        # The same two mistakes to refuse, for the same reasons: a zero connect
        # budget would fail every attempt before the SYN left the box, and a
        # non-numeric would raise from inside the Faraday stack past every
        # `rescue` in the codebase. Non-positive means nil, folding connect back
        # under `request_timeout`.
        def connect_timeout=(value)
          @connect_timeout = positive_seconds(value, "connect_timeout",
                                              "LAIN_CONNECT_TIMEOUT=0 folds connect back into request_timeout")
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

        def positive_seconds(value, knob, off_switch)
          return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

          seconds = value.is_a?(Numeric) ? value : Float(value, exception: false)
          raise ArgumentError, "#{knob} wants seconds or nil, got #{value.inspect} (#{off_switch})" if seconds.nil?

          seconds.positive? ? seconds : nil
        end
      end
    end
  end
end
