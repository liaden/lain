# frozen_string_literal: true

# The once-per-session record that the session wrote through a layout guard with
# no layout declared at all.
RSpec.describe Lain::Telemetry::TestLayoutAbsent do
  subject(:record) { described_class.new(root: "/srv/project") }

  it "journals as test_layout_absent" do
    expect(record.to_journal["type"]).to eq("test_layout_absent")
  end

  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(root: "/srv/project")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"test_layout_absent","root":"/srv/project"}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        root: "/srv/project"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing root, naming it" do
      given = {
        root: "/srv/project"
      }
      expect { described_class.new(**given.except(:root)) }.to raise_error(ArgumentError, /root/)
    end

    it "interns root" do
      first = described_class.new(root: +"v")
      second = described_class.new(root: +"v")
      expect(first.root).to equal(second.root)
    end
  end
end
