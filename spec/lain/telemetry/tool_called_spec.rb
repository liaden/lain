# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ToolCalled do
  def record(**over)
    described_class.new(tool_use_id: "tu_1", tool: "edit_file", summary: "lib/a.rb", phase: :start,
                        outcome: nil, seconds: nil, **over)
  end

  it "carries the call, its summary and where in the call it was sent" do
    expect(record).to have_attributes(tool_use_id: "tu_1", tool: "edit_file", summary: "lib/a.rb", phase: :start,
                                      outcome: nil, seconds: nil)
  end

  it "journals under its own type with every field" do
    expect(record(phase: :end, outcome: "ok", seconds: 0.4).to_journal)
      .to include("type" => "tool_called", "tool" => "edit_file", "phase" => :end, "outcome" => "ok", "seconds" => 0.4)
  end

  it "is shareable across Ractors even when built from mutable strings" do
    expect(record(summary: +"lib/a.rb", tool: +"edit_file", tool_use_id: +"tu_1", phase: :end, outcome: +"ok",
                  seconds: 0.4)).to be_deeply_frozen
  end
end
