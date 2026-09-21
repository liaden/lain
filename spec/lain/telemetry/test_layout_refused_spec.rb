# frozen_string_literal: true

# A write the write-time layout guard refused, so nothing was written.
RSpec.describe Lain::Telemetry::TestLayoutRefused do
  subject(:record) { refusal }

  def refusal(**overrides)
    described_class.new(tool_use_id: "tu_1", tool: "write_file",
                        path: "spec/unit/models/order_extra_spec.rb", rule: :elsewhere,
                        expected: "spec/unit/models/order_spec.rb", reason: "belongs elsewhere", **overrides)
  end

  # Asked here rather than left to spec/journalable_surface_spec.rb's collision
  # sweep, which cannot reach this record: `rule` admits only the guard's own
  # published list, so every generic dummy is refused and the class lands on that
  # sweep's named blind-spot list. Its two siblings are reachable there.
  it "journals as test_layout_refused" do
    expect(record.to_journal["type"]).to eq("test_layout_refused")
  end

  it "carries the rule and the path the layout wants, for a reader who sets policy per rule" do
    expect(record.to_journal).to include("rule" => :elsewhere, "expected" => "spec/unit/models/order_spec.rb")
  end

  it "names no path when the guard named none" do
    stray = refusal(tool_use_id: "tu_3", tool: "edit_file", path: "spec/x_spec.rb", rule: :stray,
                    expected: nil, reason: "stray")

    expect(stray.expected).to be_nil
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end

  it "refuses a refusal that names no path" do
    expect do
      refusal(tool_use_id: "tu_4", path: nil, rule: :stray, expected: nil, reason: "stray")
    end.to raise_error(ArgumentError, /path/)
  end

  # The rules come from the guard itself, so a rule it gains is one a record
  # accepts, and the two lists cannot drift.
  it "accepts every rule the guard publishes as refusing" do
    records = Lain::TestLayout::Guard::REFUSING.map do |rule|
      refusal(tool_use_id: "tu", path: "spec/x_spec.rb", rule:, expected: nil, reason: "refused")
    end

    expect(records.map(&:rule)).to eq(Lain::TestLayout::Guard::REFUSING)
  end

  it "refuses a rule the guard never refuses under" do
    expect do
      refusal(tool_use_id: "tu_5", path: "spec/x_spec.rb", rule: :mirrors, expected: nil, reason: "it passed")
    end.to raise_error(ArgumentError, /rule/)
  end
end
