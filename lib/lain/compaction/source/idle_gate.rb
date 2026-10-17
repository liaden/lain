# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      # Idle time is the gate; the cache flags only label the reading, because Cold#cold? is a
      # latch that stays true from one zero read to the next positive one, which on a provider with
      # no TTL is every response.
      class IdleGate
        # Seconds a provider with no cache TTL must sit idle: a pause mid-thought must never pay a
        # summarizer call, a walk to the kettle should.
        FLOOR = 120

        def initialize(floor: FLOOR)
          @floor = floor
          @latched = nil
        end

        # @param elapsed [Numeric] seconds the chat has been idle
        # @param ttl [Integer, nil] the provider's cache TTL in seconds; nil or 0 means none
        # @param cold [Boolean] the cache is confirmed cold
        # @return [Symbol] :warm until elapsed passes the TTL (or the floor when there is none),
        #   then :cold when confirmed and :presumed_cold otherwise
        def reading(elapsed:, ttl:, cold:)
          return :warm unless idle_long_enough?(elapsed, ttl)

          cold ? :cold : :presumed_cold
        end

        # @return [Boolean] false while this head is latched or the reading is warm
        def ready?(reading, head_digest)
          reading != :warm && head_digest != @latched
        end

        def latch(head_digest) = (@latched = head_digest)

        private

        def idle_long_enough?(elapsed, ttl)
          ttl&.positive? ? elapsed > ttl : elapsed >= @floor
        end
      end
    end
  end
end
