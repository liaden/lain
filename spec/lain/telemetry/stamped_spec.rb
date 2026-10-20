# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Stamped do
  let(:record) { Lain::Telemetry::Sandbox.new(tool_use_id: "tu_1", profile: :reader, trace: false, refused: []) }

  it "journals the wrapped record with the arm and the task merged in" do
    expect(described_class.new(record:, arm: "single-thread", task: "abc").to_journal)
      .to eq(record.to_journal.merge("arm" => "single-thread", "task" => "abc"))
  end

  it "leaves the wrapped record unstamped" do
    described_class.new(record:, arm: "a", task: "t")

    expect(record.to_journal).not_to include("arm", "task")
  end
end
