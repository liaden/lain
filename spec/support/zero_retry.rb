# frozen_string_literal: true

# A Provider::HTTP::Configuration whose retry loop still runs -- max_retries
# stays at the production default -- but sleeps zero seconds between attempts.
# faraday-retry's backoff schedule (interval * backoff_factor ** attempt) is
# production policy, not the behavior under test: the transport-error specs
# assert which error finally surfaces (or that retries fired, via the
# config's retry_block seam), and every real second slept is pure suite time.
# retry_interval multiplies every term of the schedule, including the
# randomness jitter, so zeroing it and the factor zeroes the whole schedule.
module ZeroRetry
  def zero_retry_config
    config = Lain::Provider::HTTP::Configuration.new
    config.retry_interval = 0
    config.retry_backoff_factor = 0
    config
  end
end

RSpec.configure { |config| config.include ZeroRetry }
