# frozen_string_literal: true

# The once-per-session record that the session wrote through a layout guard with
# no layout declared at all.
RSpec.describe Lain::Telemetry::TestLayoutAbsent do
  subject(:record) { described_class.new(root: "/srv/project") }

  it "journals as test_layout_absent" do
    expect(record.to_journal["type"]).to eq("test_layout_absent")
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
