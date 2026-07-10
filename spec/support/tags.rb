# frozen_string_literal: true

# Which specs are allowed to spend money, and which are allowed to touch the network.
#
# The default posture is offline and free. `webmock/rspec` blocks outbound HTTP for every
# example; a tag is the only way through. This file owns the gating for every such tag, so
# there is exactly one place to read the answer to "can this spec cost me money?"
#
#   :integration  hits the real API. Opt-in, requires BOTH env vars.
#   :vcr          replays a recorded cassette. Free, offline. See vcr_configuration.rb.
#   :live         end-to-end differential run against the API. Opt-in, costs real money.

# Integration specs talk to the real Claude API. They cost money and are nondeterministic,
# so they are skipped unless BOTH are set:
#
#     LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
INTEGRATION_ENABLED = ENV["LAIN_INTEGRATION"] == "1" && !ENV["ANTHROPIC_API_KEY"].to_s.empty?

RSpec.configure do |config|
  # Integration examples punch through WebMock for their duration only; the block is
  # restored even if the example raises.
  config.around(:each, :integration) do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
  end

  unless INTEGRATION_ENABLED
    config.filter_run_excluding(:integration)

    config.before(:suite) do
      RSpec.configuration.reporter.message(
        "Skipping :integration specs. Set LAIN_INTEGRATION=1 and ANTHROPIC_API_KEY to run them."
      )
    end
  end

  # :vcr specs replay a committed cassette through VCR/webmock and are free and
  # offline BY DEFAULT -- no exclusion needed to run them; that is the whole
  # appeal. The one thing that needs guarding is RECORDING: LAIN_RECORD=1
  # flips vcr_configuration.rb's default from :none to :new_episodes, and
  # recording without a real key would either fail against the API or, worse,
  # commit a cassette holding a failed, keyless interaction. Refuse up front
  # rather than silently doing that.
  config.before(:suite) do
    recording_without_credentials = ENV["LAIN_RECORD"] == "1" && ENV["ANTHROPIC_API_KEY"].to_s.empty?
    raise "LAIN_RECORD=1 requires ANTHROPIC_API_KEY to record real interactions." if recording_without_credentials
  end
end

# :live specs run a full round trip against the real API with no cassette to
# fall back to -- real money on every single run, not just the first. Opt-in
# on exactly the same shape as :integration: BOTH env vars, or it is skipped.
#
#     LAIN_LIVE=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
LIVE_ENABLED = ENV["LAIN_LIVE"] == "1" && !ENV["ANTHROPIC_API_KEY"].to_s.empty?

RSpec.configure do |config|
  config.around(:each, :live) do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
  end

  unless LIVE_ENABLED
    config.filter_run_excluding(:live)

    config.before(:suite) do
      RSpec.configuration.reporter.message(
        "Skipping :live specs. Set LAIN_LIVE=1 and ANTHROPIC_API_KEY to run them."
      )
    end
  end
end
