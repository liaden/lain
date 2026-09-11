# frozen_string_literal: true

# The three records the write-time layout guard journals: a write it refused, a
# test it let through ahead of the class it describes, and -- once per session --
# that no layout was declared at all.
RSpec.describe "the test layout records" do
  let(:refused) do
    Lain::Telemetry::TestLayoutRefused.new(tool_use_id: "tu_1", tool: "write_file",
                                           path: "spec/unit/models/order_extra_spec.rb", rule: :elsewhere,
                                           expected: "spec/unit/models/order_spec.rb", reason: "belongs elsewhere")
  end
  let(:deferred) do
    Lain::Telemetry::TestLayoutDeferred.new(tool_use_id: "tu_2", tool: "write_file",
                                            path: "spec/unit/models/refund_spec.rb", reason: "no source yet")
  end
  let(:absent) { Lain::Telemetry::TestLayoutAbsent.new(root: "/srv/project") }

  it "journals each under its own type" do
    expect([refused, deferred, absent].map { |record| record.to_journal["type"] })
      .to eq(%w[test_layout_refused test_layout_deferred test_layout_absent])
  end

  it "carries the rule and the path the layout wants, for a reader who sets policy per rule" do
    expect(refused.to_journal).to include("rule" => :elsewhere, "expected" => "spec/unit/models/order_spec.rb")
  end

  it "names no path when the guard named none" do
    stray = Lain::Telemetry::TestLayoutRefused.new(tool_use_id: "tu_3", tool: "edit_file", path: "spec/x_spec.rb",
                                                   rule: :stray, expected: nil, reason: "stray")

    expect(stray.expected).to be_nil
  end

  it "is deeply frozen" do
    expect([refused, deferred, absent]).to all(satisfy { |record| Ractor.shareable?(record) })
  end

  it "refuses a refusal that names no path" do
    expect do
      Lain::Telemetry::TestLayoutRefused.new(tool_use_id: "tu_4", tool: "write_file", path: nil, rule: :stray,
                                             expected: nil, reason: "stray")
    end.to raise_error(ArgumentError, /path/)
  end

  # The rules come from the guard itself, so a rule it gains is one a record
  # accepts, and the two lists cannot drift.
  it "accepts every rule the guard publishes as refusing" do
    records = Lain::TestLayout::Guard::REFUSING.map do |rule|
      Lain::Telemetry::TestLayoutRefused.new(tool_use_id: "tu", tool: "write_file", path: "spec/x_spec.rb",
                                             rule:, expected: nil, reason: "refused")
    end

    expect(records.map(&:rule)).to eq(Lain::TestLayout::Guard::REFUSING)
  end

  it "refuses a rule the guard never refuses under" do
    expect do
      Lain::Telemetry::TestLayoutRefused.new(tool_use_id: "tu_5", tool: "write_file", path: "spec/x_spec.rb",
                                             rule: :mirrors, expected: nil, reason: "it passed")
    end.to raise_error(ArgumentError, /rule/)
  end
end
