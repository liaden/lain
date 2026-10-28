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

  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(tool_use_id: "tu_1",
                                   profile: :workspace,
                                   trace: true,
                                   refused: ["/bin/curl"],
                                   created_sealed: ["/repo/.git/commondir"],
                                   kept_tmpdir: "/t/lain-call-1")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"sandbox","tool_use_id":"tu_1","profile":"workspace","trace":true,' \
        '"refused":["/bin/curl"],"created_sealed":["/repo/.git/commondir"],' \
        '"kept_tmpdir":"/t/lain-call-1"}'
      )
    end

    it "journals byte for byte with optional fields at their defaults (nil)" do
      record = described_class.new(tool_use_id: "tu_1",
                                   profile: :reader,
                                   trace: false,
                                   refused: [])
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"sandbox","tool_use_id":"tu_1","profile":"reader","trace":false,"refused":[],' \
        '"created_sealed":[],"kept_tmpdir":null}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        tool_use_id: "tu_1",
        profile: :workspace,
        trace: true,
        refused: ["/bin/curl"],
        created_sealed: ["/repo/.git/commondir"],
        kept_tmpdir: "/t/lain-call-1"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing tool_use_id, naming it" do
      given = {
        tool_use_id: "tu_1",
        profile: :workspace,
        trace: true,
        refused: ["/bin/curl"],
        created_sealed: ["/repo/.git/commondir"],
        kept_tmpdir: "/t/lain-call-1"
      }
      expect { described_class.new(**given.except(:tool_use_id)) }.to raise_error(ArgumentError, /tool_use_id/)
    end

    it "refuses an unknown keyword with ArgumentError" do
      expect do
        described_class.new(tool_use_id: "t", profile: :reader, trace: false, refused: [],
                            bogus: 1)
      end.to raise_error(ArgumentError, /bogus/)
    end
  end
end
