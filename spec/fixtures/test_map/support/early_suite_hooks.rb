# frozen_string_literal: true

require "rspec/core"
require_relative "attribution_probe"

# Required ahead of spec_helper, so these suite hooks register before attribution's own.
RSpec.configure do |config|
  config.before(:suite) { AttributionProbe.record("early before suite", nil) }
  config.after(:suite) { AttributionProbe.record("early after suite", nil) }
end
