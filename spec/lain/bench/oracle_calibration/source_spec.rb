# frozen_string_literal: true

RSpec.describe Lain::Bench::OracleCalibration::Source do
  describe ".backend" do
    it "yields a backend whose egress guard is bound, not fail-closed" do
      backend = described_class.send(:backend)

      expect(backend.egress_literals.egress.refused)
        .to eq(Lain::Sensitivity::Secrets::Source::DEFAULT.egress.refused)
    end
  end
end
