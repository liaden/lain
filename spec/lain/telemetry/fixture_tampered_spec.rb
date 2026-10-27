# frozen_string_literal: true

# The record that an arm edited the tests it was to be graded by, so the run is
# invalid rather than low.
RSpec.describe Lain::Telemetry::FixtureTampered do
  subject(:record) { described_class.new(arm: "one-shot", paths: ["spec/unit/a_spec.rb"]) }

  it "journals as fixture_tampered, naming the arm and the paths" do
    expect(record.to_journal).to include("type" => "fixture_tampered", "arm" => "one-shot",
                                         "paths" => ["spec/unit/a_spec.rb"])
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
