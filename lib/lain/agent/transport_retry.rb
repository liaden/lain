# frozen_string_literal: true

module Lain
  class Agent
    # Re-sends a round trip whose connection dropped ({StopReason.dropped?}).
    # One dropped TLS read used to end a run of hours, because Faraday's retry
    # middleware never sees a failure raised past its adapter.
    #
    # The schedule is {Provider::HTTP::Configuration}'s default one, which is
    # Ollama's; Anthropic lowers its own retry count, and this one stays put.
    # Each retry and the give-up are journaled as a {Telemetry::ProviderRetry}
    # numbered as the providers' retry taps number theirs, with {LAYER} as the
    # path so a reader can tell the two layers' records apart.
    class TransportRetry
      SCHEDULE = Provider::HTTP::Configuration.new.then do |config|
        { attempts: config.max_retries + 1, interval: config.retry_interval, factor: config.retry_backoff_factor }
      end.freeze
      private_constant :SCHEDULE

      LAYER = "agent"

      # Calls the round trip once and retries nothing: what a {ModelCaller}
      # nobody handed a retry does.
      module NONE
        # @yieldreturn [Object] the round trip's answer
        # @return [Object] that answer
        def self.call = yield
      end

      # @param journal [#<<] where each retry is recorded
      # @param sleeper [#call] waits the backoff, in seconds
      def initialize(journal: Channel::Null.instance, sleeper: ->(seconds) { Kernel.sleep(seconds) })
        @journal = journal
        @sleeper = sleeper
      end

      # `retry` restarts the attempt from outside the rescue, so a later
      # attempt's own failure carries no earlier drop as its cause; called from
      # inside the rescue instead, every later error would read as a drop.
      #
      # @yieldreturn [Object] the round trip's answer
      # @return [Object] the first answer a round trip gave
      # @raise [Exception] the last drop once every attempt dropped, or any other failure at once
      def call
        number = 0
        begin
          number += 1
          yield
        rescue StandardError => e
          raise unless StopReason.dropped?(e) && backed_off?(number, e)

          retry
        end
      end

      private

      def backed_off?(number, error)
        wait = backoff(number)
        @journal << Telemetry::ProviderRetry.new(attempt: number, will_retry_in: wait, reason: drop_name(error),
                                                 path: LAYER)
        return false if wait.nil?

        @sleeper.call(wait)
        true
      end

      def backoff(number)
        SCHEDULE[:interval] * (SCHEDULE[:factor]**(number - 1)) if number < SCHEDULE[:attempts]
      end

      def drop_name(error)
        Enumerator.produce(error, &:cause).take_while(&:itself).find { |cause| cause.is_a?(Faraday::SSLError) }
                  .class.name
      end
    end
  end
end
