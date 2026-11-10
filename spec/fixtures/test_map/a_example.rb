# frozen_string_literal: true

# rubocop:disable RSpec/NoExpectationExample -- these examples report to the parent spec, which asserts
require "open3"
require "rbconfig"
require "rspec/core/sandbox"
require_relative "support/attribution_probe"

AttributionProbe.record("load a")

RSpec.describe "attribution fixture a" do
  before(:context) { AttributionProbe.record("context a") } # rubocop:disable RSpec/BeforeAfterAll

  it_behaves_like "an attribution probe", "shared a"

  it("reads its own file") { AttributionProbe.record("example a") }

  it("attributes a thread it starts") { Thread.new { AttributionProbe.record("thread a") }.join }

  it "hands a child no recording directory" do
    child, = Open3.capture2(RbConfig.ruby, "-e", 'print ENV["LAIN_TEST_MAP_DIR"].to_s')
    AttributionProbe.record("child a", child)
  end

  it("sees whether coverage runs") { AttributionProbe.record("coverage", Coverage.running?) }

  it "keeps its file through a sandboxed group run inside it" do
    RSpec::Core::Sandbox.sandboxed do |config|
      RSpec.describe("sandboxed") { it("passes") { AttributionProbe.record("inside sandbox") } }
           .run(RSpec::Core::Reporter.new(config))
    end
    AttributionProbe.record("after sandbox")
  end
end

RSpec.describe "attribution fixture a, second group" do
  it("reads its own file") { AttributionProbe.record("second group a") }
end
# rubocop:enable RSpec/NoExpectationExample
