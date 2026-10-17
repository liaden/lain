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
end
