# frozen_string_literal: true

# rubocop:disable RSpec/NoExpectationExample -- these examples report to the parent spec, which asserts
require "coverage"
require "json"

# Appends what Attribution named at a labelled moment, for the parent spec to read back.
module AttributionProbe
  module_function

  # @param label [String] the moment being probed
  # @param value [Object] what was seen there; defaults to the current spec file
  # @return [void]
  def record(label, value = TestMap::Attribution.current)
    File.write(ENV.fetch("ATTRIBUTION_PROBE_OUT"), "#{JSON.generate(label:, value:)}\n", mode: "a")
  end
end

RSpec.shared_examples "an attribution probe" do |label|
  it("reads the including file") { AttributionProbe.record(label) }
end
# rubocop:enable RSpec/NoExpectationExample
