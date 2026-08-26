# frozen_string_literal: true

module Lain
  module Compaction
    # WHETHER the prompt cache is cold, kept apart from {Need} (whether a
    # compaction is warranted at all) and from the scheduling policy that
    # decides whether a *needed* compaction waits for a cold cache.
    #
    # Coldness is two independent signals, not one. Idle time alone is a GUESS
    # -- a provider's TTL is nominal, not a guarantee the server evicted the
    # entry -- and `cache_read_input_tokens == 0` alone cannot tell "genuinely
    # cold" from "first turn ever, nothing written to cache yet". So
    # idle-past-TTL raises only a PENDING mark, and the next response's
    # cache-read either CONFIRMS it or CANCELS it: a hit proves the cache was
    # warm the whole time.
    #
    # A provider whose `cache_profile` carries no real TTL -- an
    # OpenAI-compatible arm with nothing to name, or Ollama's
    # `NO_CACHING_PROFILE` (`ttl: 0`) -- has nothing for idle time to compare
    # against, so {#idle!} is a no-op and {#observe} falls back to the
    # `cache_read == 0` signal ALONE. Assuming Anthropic's sliding-TTL
    # semantics for a provider that has none would mean this detector simply
    # never fires for that arm.
    class Cold
      # Which path confirmed the cache cold: `:idle_confirmed` for
      # idle-past-TTL corroborated by a zero cache-read, `:signal_only` for a
      # TTL-less provider's zero cache-read confirming on its own.
      REASONS = %i[idle_confirmed signal_only].freeze

      CacheColdConfirmed = Data.define(:reason) do
        include Telemetry::Journalable

        def initialize(reason:)
          unless REASONS.include?(reason)
            raise ArgumentError, "reason must be one of #{REASONS.inspect}, got #{reason.inspect}"
          end

          super
        end
      end

      # @param cache_profile [Hash] a provider's `#cache_profile`;
      #   only `:ttl` is read here.
      # @param journal [#<<] where the cold confirmation lands; the Null
      #   channel by default, so no caller guards `if journal`.
      def initialize(cache_profile:, journal: Channel::Null.instance)
        @ttl = cache_profile[:ttl]
        @journal = journal
        @pending = false
        @cold = false
      end

      # @return [Boolean] idle time alone raised a mark awaiting confirmation
      def pending? = @pending

      # @return [Boolean] the cache is CONFIRMED cold
      def cold? = @cold

      # The idle-time signal. A no-op for a TTL-less provider: nothing here
      # raises a pending mark it has no TTL to compare against.
      #
      # @param idle_seconds [Numeric] the caller's own measurement of time
      #   since the cache was last touched
      # @return [void]
      def idle!(idle_seconds)
        @pending = true if ttl? && idle_seconds > @ttl
      end

      # The response signal, fed every model response's usage. The STRING-keyed
      # read happens INSIDE this method on purpose: `TurnUsage#usage` is
      # `Canonical.normalize`d wire form (String keys only), and a caller who
      # extracted the count themselves could reach for
      # `usage[:cache_read_input_tokens]` and get a silent `nil` -- which reads
      # as zero and confirms cold on a WARM turn.
      #
      # A zero read confirms cold: a pending idle mark on a TTL-bearing
      # provider, or, TTL-less, on its own. A positive read cancels a pending
      # OR already-confirmed mark, because a hit means the cache is warm right
      # now regardless of what idle time guessed.
      #
      # @param turn_usage [#usage, Hash] a {Telemetry::TurnUsage} (or same
      #   duck) or its `usage` Hash directly
      # @return [void]
      def observe(turn_usage)
        return cancel! if cache_read_input_tokens(turn_usage).positive?

        confirm!(ttl? ? :idle_confirmed : :signal_only) if @pending || !ttl?
      end

      private

      def cache_read_input_tokens(turn_usage)
        usage = turn_usage.respond_to?(:usage) ? turn_usage.usage : turn_usage
        usage["cache_read_input_tokens"].to_i
      end

      def ttl? = !@ttl.nil? && !@ttl.zero?

      def confirm!(reason)
        @pending = false
        @cold = true
        @journal << CacheColdConfirmed.new(reason:)
      end

      def cancel!
        @pending = false
        @cold = false
      end
    end
  end
end
