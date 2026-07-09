# frozen_string_literal: true

require "lain"
require "webmock/rspec"

# Integration specs talk to the real Claude API. They cost money and are nondeterministic,
# so they are opt-in and are skipped unless BOTH are set:
#
#     LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
#
# Tag them `:integration`. Everything else must run offline.
INTEGRATION_ENABLED = ENV["LAIN_INTEGRATION"] == "1" && !ENV["ANTHROPIC_API_KEY"].to_s.empty?

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Order-dependent specs are a lie we tell ourselves. Surface them.
  config.order = :random
  Kernel.srand config.seed

  # `webmock/rspec` blocks outbound HTTP for every example. Integration examples punch
  # through for their duration only; the block is restored even if the example raises.
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
