# frozen_string_literal: true

# A test the write-time layout guard let through ahead of the class it describes.
RSpec.describe Lain::Telemetry::TestLayoutDeferred do
  subject(:record) do
    described_class.new(tool_use_id: "tu_2", tool: "write_file",
                        path: "spec/unit/models/refund_spec.rb", reason: "no source yet")
  end

  it "journals as test_layout_deferred" do
    expect(record.to_journal["type"]).to eq("test_layout_deferred")
  end

  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(tool_use_id: "tu_1",
                                   tool: "write_file",
                                   path: "spec/foo_spec.rb",
                                   reason: "class not yet written")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"test_layout_deferred","tool_use_id":"tu_1","tool":"write_file",' \
        '"path":"spec/foo_spec.rb","reason":"class not yet written"}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        tool_use_id: "tu_1",
        tool: "write_file",
        path: "spec/foo_spec.rb",
        reason: "class not yet written"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing tool_use_id, naming it" do
      given = {
        tool_use_id: "tu_1",
        tool: "write_file",
        path: "spec/foo_spec.rb",
        reason: "class not yet written"
      }
      expect { described_class.new(**given.except(:tool_use_id)) }.to raise_error(ArgumentError, /tool_use_id/)
    end

    it "interns tool_use_id" do
      first = described_class.new(tool_use_id: +"v", tool: "w", path: "p", reason: "r")
      second = described_class.new(tool_use_id: +"v", tool: "w", path: "p", reason: "r")
      expect(first.tool_use_id).to equal(second.tool_use_id)
    end

    it "interns tool" do
      first = described_class.new(tool_use_id: "t", tool: +"v", path: "p", reason: "r")
      second = described_class.new(tool_use_id: "t", tool: +"v", path: "p", reason: "r")
      expect(first.tool).to equal(second.tool)
    end

    it "interns path" do
      first = described_class.new(tool_use_id: "t", tool: "w", path: +"v", reason: "r")
      second = described_class.new(tool_use_id: "t", tool: "w", path: +"v", reason: "r")
      expect(first.path).to equal(second.path)
    end

    it "interns reason" do
      first = described_class.new(tool_use_id: "t", tool: "w", path: "p", reason: +"v")
      second = described_class.new(tool_use_id: "t", tool: "w", path: "p", reason: +"v")
      expect(first.reason).to equal(second.reason)
    end
  end
end
