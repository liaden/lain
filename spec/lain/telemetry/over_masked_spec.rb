# frozen_string_literal: true

require "json"

# What a tool result masked whole, because a scan could not finish, leaves in the Journal.
RSpec.describe Lain::Telemetry::OverMasked do
  subject(:event) { described_class.new(tool: "bash", shape: "github token", spans: 2) }

  it "carries the tool, the shape and the count of spans" do
    expect(event).to have_attributes(tool: "bash", shape: "github token", spans: 2)
  end

  it "is a frozen value object, shareable even from mutable Strings" do
    expect(described_class.new(tool: +"bash", shape: +"github token", spans: 2)).to be_deeply_frozen
  end

  it "journals as an over_masked record holding names and a count only" do
    expect(event.to_journal).to eq("type" => "over_masked", "tool" => "bash", "shape" => "github token", "spans" => 2)
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq(event.to_journal)
  end

  it "rejects a count that is not a positive Integer" do
    [nil, 0, -1, 1.5, { "leaked" => "bytes" }].each do |bad|
      expect { described_class.new(tool: "bash", shape: "x", spans: bad) }.to raise_error(ArgumentError, /spans/)
    end
  end

  it "rejects a tool or shape that is not a name" do
    expect { described_class.new(tool: nil, shape: "x", spans: 1) }.to raise_error(ArgumentError, /tool/)
    expect { described_class.new(tool: "bash", shape: "", spans: 1) }.to raise_error(ArgumentError, /shape/)
  end

  it "is read back from the journal by its type" do
    expect(Lain::Telemetry.read(event.to_journal)).to eq(event)
  end
end
