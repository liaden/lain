# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Telemetry::ToolOutput do
  subject(:event) { described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi") }

  it "rejects an unknown stream" do
    expect { described_class.new(tool_use_id: "t", stream: :nope, bytes: "x") }
      .to raise_error(ArgumentError)
  end

  it "is a frozen value object with structural equality" do
    twin = described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
    expect(event.hash).to eq(twin.hash)
  end

  it "is Ractor-shareable (no reachable mutable state)" do
    expect(event).to be_deeply_frozen
  end

  describe "#to_journal" do
    it "is a JSON object of the attributes tagged with a snake_case type" do
      expect(event.to_journal).to eq(
        "type" => "tool_output", "tool_use_id" => "t1", "stream" => :stdout, "bytes" => "hi"
      )
    end

    it "round-trips through JSON to a parseable line" do
      expect(JSON.parse(JSON.generate(event.to_journal))).to include(
        "type" => "tool_output", "stream" => "stdout"
      )
    end
  end

  describe "journal bytes" do
    it "journals the stream as a String and the bytes untouched" do
      expect(JSON.generate(described_class.new(tool_use_id: "tu_1", stream: :stdout, bytes: "hi\n").to_journal)).to eq(
        '{"type":"tool_output","tool_use_id":"tu_1","stream":"stdout","bytes":"hi\n"}'
      )
    end

    it "refuses a keyword it does not declare" do
      expect { described_class.new(tool_use_id: "t", stream: :stdout, bytes: "x", stray: 1) }
        .to raise_error(ArgumentError, /stray/)
    end
  end

  it "reads its own journal line back, the stream a Symbol again" do
    io = StringIO.new
    Lain::Journal.new(io:).record(event)

    expect(Lain::Telemetry.read(Lain::Journal.parse(io.string))).to eq(event).and have_attributes(stream: :stdout)
  end
end
