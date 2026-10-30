# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Readers do
  describe ".records_under" do
    it "walks into a namespace defined under the scope, but not into a constant aliasing one defined elsewhere" do
      record = Data.define(:x) { include Lain::Telemetry::Journalable }
      stub_const("Lain::Telemetry::ProbeScope", Module.new)
      stub_const("Lain::Telemetry::ProbeScope::Inner", Module.new)
      stub_const("Lain::Telemetry::ProbeScope::Inner::Kept", record)
      stub_const("Lain::Telemetry::ProbeScope::Aliased", Lain::Telemetry::AskSettled)

      expect(described_class.records_under(Lain::Telemetry::ProbeScope)).to eq([Lain::Telemetry::ProbeScope::Inner::Kept])
    end
  end
end
