# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Sandbox do
  def record(**stamp) = described_class.new(tool_use_id: "tu_1", profile: :reader, trace: false, refused: [], **stamp)

  it "reads arm and task as nil when none was given, as a line from before the stamp does" do
    expect(record).to have_attributes(arm: nil, task: nil)
  end

  it "journals the arm and the task it was stamped with" do
    expect(record(arm: "single-thread", task: "abc").to_journal)
      .to include("type" => "sandbox", "arm" => "single-thread", "task" => "abc")
  end

  it "stays Ractor shareable when stamped" do
    expect(Ractor.shareable?(record(arm: +"a", task: +"t"))).to be(true)
  end
end
