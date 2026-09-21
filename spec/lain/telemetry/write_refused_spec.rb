# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::WriteRefused do
  subject(:event) { described_class.new(tool_use_id: "tu_1", pattern: "aws access key id") }

  it "carries the tool_use_id and the NAME of the pattern that matched" do
    expect(event.tool_use_id).to eq("tu_1")
    expect(event.pattern).to eq("aws access key id")
  end

  it "is a frozen value object with structural equality" do
    twin = described_class.new(tool_use_id: "tu_1", pattern: "aws access key id")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
    expect(event.hash).to eq(twin.hash)
  end

  it "is Ractor-shareable even when built from mutable Strings" do
    mutable = described_class.new(tool_use_id: +"tu_1", pattern: +"aws access key id")
    expect(mutable).to be_deeply_frozen
  end

  it "rejects a nil pattern loudly -- a refusal record must name what matched" do
    expect { described_class.new(tool_use_id: "tu_1", pattern: nil) }
      .to raise_error(ArgumentError, /pattern/)
  end

  it "journals as a write_refused record that round-trips through JSON" do
    expect(event.to_journal).to eq(
      "type" => "write_refused", "tool_use_id" => "tu_1", "pattern" => "aws access key id"
    )
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq(
      "type" => "write_refused", "tool_use_id" => "tu_1", "pattern" => "aws access key id"
    )
  end
end
