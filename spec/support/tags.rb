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
end
