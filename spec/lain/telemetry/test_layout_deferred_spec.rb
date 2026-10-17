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
end
