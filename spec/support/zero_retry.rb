# frozen_string_literal: true

# A Provider::HTTP::Configuration whose retry loop still runs -- max_retries
# stays at the production default -- but sleeps zero seconds between attempts.
# faraday-retry's backoff schedule (interval * backoff_factor ** attempt) is
# production policy, not the behavior under test: the transport-error specs
# assert which error finally surfaces (or that retries fired, via the
# config's retry_block seam), and every real second slept is pure suite time.
# retry_interval multiplies every term of the schedule, including the
# randomness jitter, so zeroing it and the factor zeroes the whole schedule.
#
# == The envelope must be shaped BEFORE the provider is constructed
#
# This returns a config to HAND IN, never one to mutate afterwards, and that is
# not a style preference. `Provider::HTTP::Provider#initialize` builds its
# `Connection` eagerly, `Connection#initialize` assembles the middleware stack
# there and then ("Faraday's builder is StackLocked after the first request"),
# and `MiddlewareStack#retry_options` snapshots interval, backoff factor and max
# into the Hash faraday-retry is built with. A later `config.retry_interval = 0`
# therefore changes nothing at all: measured against a provider already built,
# the middleware still read `interval=0.1 backoff_factor=2.0 max=3`, and a
# post-construction `max_retries = 2` still spent three retries. A helper that
# mutates after construction is dead code that reads like a control.
module ZeroRetry
  # @param max_retries [Integer, nil] the retry BUDGET, when a spec is about
  #   exhausting it; nil leaves the production default in place.
  def zero_retry_config(max_retries: nil)
    config = Lain::Provider::HTTP::Configuration.new
    config.retry_interval = 0
    config.retry_backoff_factor = 0
    config.max_retries = max_retries unless max_retries.nil?
    config
  end
end

RSpec.configure { |config| config.include ZeroRetry }
