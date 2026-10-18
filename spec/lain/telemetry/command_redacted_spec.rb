# frozen_string_literal: true

require "json"

# What a masked bash result leaves in the Journal.
RSpec.describe Lain::Telemetry::CommandRedacted do
  subject(:event) { described_class.new(tool_use_id: "tu_9", regions: 2) }

  it "carries the tool_use_id and the count of masked spans" do
    expect(event).to have_attributes(tool_use_id: "tu_9", regions: 2)
  end

  it "is a frozen value object, shareable even from mutable Strings" do
    expect(described_class.new(tool_use_id: +"tu_9", regions: 2)).to be_deeply_frozen
  end

  it "journals as a command_redacted record holding counts only" do
    expect(event.to_journal).to eq("type" => "command_redacted", "tool_use_id" => "tu_9", "regions" => 2)
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq(event.to_journal)
  end

  it "rejects a count that is not a non-negative Integer" do
    [nil, -1, 1.5, { "leaked" => "bytes" }].each do |bad|
      expect { described_class.new(tool_use_id: "tu_9", regions: bad) }.to raise_error(ArgumentError, /regions/)
    end
  end
end
