# frozen_string_literal: true

# rubocop:disable RSpec/NoExpectationExample -- these examples report to the parent spec, which asserts
require_relative "support/attribution_probe"

AttributionProbe.record("load b")

RSpec.describe "attribution fixture b" do
  it("reads its own file") { AttributionProbe.record("example b") }
end
# rubocop:enable RSpec/NoExpectationExample
