# frozen_string_literal: true

module Lain
  class Provider
    # Says a transport retry in both places it is owed: the display channel, for
    # the human watching, and the session journal, because a retry that bills
    # twice and leaves no record hides spend from a bench whose headline metric
    # is cost. Both providers' retry taps narrate through this, so they cannot
    # disagree about what an attempt number means.
    class RetryNarration
      # @param channel [#<<] the live stream the human reads
      # @param journal [#<<] the session's record; the Null channel by default
      def initialize(channel:, journal: Channel::Null::INSTANCE)
        @channel = channel
        @journal = journal
      end

      # @param retry_count [Integer] retries already made, so the retry just fired is one past it
      # @param will_retry_in [Float, nil] the backoff in seconds
      # @param status [Integer, nil] the failed attempt's HTTP status
      # @param exception [Exception] what the attempt failed with
      def retried(retry_count:, will_retry_in:, status:, exception:)
        say(attempt: retry_count + 1, will_retry_in:, status:, exception:)
      end

      # `max` is the RETRY count; an original try plus `max` retries is `max + 1`
      # attempts, and the give-up line names the last of them.
      # @param max [Integer] the retry budget that ran out
      # @param status [Integer, nil] the last attempt's HTTP status
      # @param exception [Exception] what the last attempt failed with
      def exhausted(max:, status:, exception:)
        say(attempt: max + 1, will_retry_in: nil, status:, exception:)
      end

      private

      def say(attempt:, will_retry_in:, status:, exception:)
        event = Telemetry::ProviderRetry.new(attempt:, will_retry_in:, status:, reason: exception.class.name)
        @channel.push(event)
        @journal << event
      end
    end
  end
end
