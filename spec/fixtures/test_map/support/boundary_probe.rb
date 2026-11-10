# frozen_string_literal: true

require_relative "attribution_probe"

# Loaded through `--require`, so it registers before the first spec file loads and sees every boundary.
returned = TestMap::Attribution.on_boundary do |leaving, entering|
  AttributionProbe.record("boundary", [leaving, entering])
end
AttributionProbe.record("on_boundary returns nil", returned.nil?)

RSpec.configure do |config|
  config.before(:suite) { AttributionProbe.record("before suite") }
  config.after(:suite) { AttributionProbe.record("after suite") }
end
