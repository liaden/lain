# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Sandbox do
  def record = described_class.new(tool_use_id: "tu_1", profile: :reader, trace: false, refused: [])

  it "journals no arm or task of its own" do
    expect(record.to_journal).to eq(
      "type" => "sandbox", "tool_use_id" => "tu_1", "profile" => :reader, "trace" => false, "refused" => [],
      "created_sealed" => [], "kept_tmpdir" => nil
    )
  end

  it "journals the sealed paths a call created" do
    created = described_class.new(tool_use_id: "tu_1", profile: :workspace, trace: true, refused: [],
                                  created_sealed: ["/repo/.git/commondir"])
    expect(created.to_journal).to include("created_sealed" => ["/repo/.git/commondir"])
    expect(Ractor.shareable?(created)).to be(true)
  end

  it "journals a call's TMPDIR that could not be removed" do
    kept = described_class.new(tool_use_id: "tu_1", profile: :workspace, trace: true, refused: [],
                               kept_tmpdir: "/t/lain-call-1")
    expect(kept.to_journal).to include("kept_tmpdir" => "/t/lain-call-1")
  end

  it "stays Ractor shareable" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
