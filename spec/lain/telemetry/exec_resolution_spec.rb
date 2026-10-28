# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ExecResolution do
  let(:stage) { Lain::Shell::Executable.unresolved("cat").to_journal }

  it "is shareable across Ractors even built from mutable Strings" do
    loose = stage.transform_values { |value| value.is_a?(String) ? value.dup : value }
    record = described_class.new(tool_use_id: +"tu_1", stages: [loose])

    expect(record).to be_deeply_frozen
  end

  it "writes one exec_resolution line carrying each stage as journalled" do
    io = StringIO.new
    Lain::Journal.new(io:).record(described_class.new(tool_use_id: "tu_1", stages: [stage]))

    expect(JSON.parse(io.string.lines.first))
      .to include("type" => "exec_resolution", "tool_use_id" => "tu_1", "stages" => [JSON.parse(JSON.generate(stage))])
  end

  it "journals byte for byte, an empty stage list included" do
    parsed = { "name" => "cat", "path" => "/bin/cat", "basis" => "parsed", "cwd" => nil }

    expect(JSON.generate(described_class.new(tool_use_id: "tu_1", stages: [parsed]).to_journal))
      .to eq('{"type":"exec_resolution","tool_use_id":"tu_1","stages":' \
             '[{"name":"cat","path":"/bin/cat","basis":"parsed","cwd":null}]}')
    expect(JSON.generate(described_class.new(tool_use_id: "tu_2", stages: []).to_journal))
      .to eq('{"type":"exec_resolution","tool_use_id":"tu_2","stages":[]}')
  end

  it "shares the bytes of the tool_use_id between 2 equal records" do
    one = described_class.new(tool_use_id: +"tu_1", stages: [])
    other = described_class.new(tool_use_id: +"tu_1", stages: [])

    expect(one.tool_use_id).to equal(other.tool_use_id)
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { described_class.new(tool_use_id: "tu_1", stages: [], extra: 1) }.to raise_error(ArgumentError, /extra/)
  end
end
