# frozen_string_literal: true

require "json"

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

  it "journals byte for byte" do
    record = described_class.new(arm: "one-shot", paths: ["spec/a_spec.rb", "spec/b_spec.rb"])

    expect(JSON.generate(record.to_journal))
      .to eq('{"type":"fixture_tampered","arm":"one-shot","paths":["spec/a_spec.rb","spec/b_spec.rb"]}')
  end

  it "shares the bytes of the arm and of every path between 2 equal records" do
    build = -> { described_class.new(arm: +"one-shot", paths: [+"spec/a_spec.rb", +"spec/b_spec.rb"]) }
    one = build.call
    other = build.call

    expect(one.arm).to equal(other.arm)
    expect(one.paths.zip(other.paths).map { |left, right| left.equal?(right) }).to eq([true, true])
  end

  it "writes a Pathname path as its string" do
    expect(described_class.new(arm: "a", paths: [Pathname("spec/a_spec.rb")]).paths).to eq(["spec/a_spec.rb"])
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { described_class.new(arm: "a", paths: [], extra: 1) }.to raise_error(ArgumentError, /extra/)
  end
end
