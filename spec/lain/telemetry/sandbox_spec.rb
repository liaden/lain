# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Sandbox do
  def record = described_class.new(tool_use_id: "tu_1", profile: :reader, trace: false, refused: [])

  it "journals no arm or task of its own" do
    expect(record.to_journal).to eq(
      "type" => "sandbox", "tool_use_id" => "tu_1", "profile" => :reader, "trace" => false, "refused" => []
    )
  end

  it "stays Ractor shareable" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
