# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Salvaged do
  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(request_digest: "blake3:req",
                                   head_before: "blake3:before",
                                   head_after: "blake3:after")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"salvaged","request_digest":"blake3:req","head_before":"blake3:before",' \
        '"head_after":"blake3:after"}'
      )
    end

    it "journals byte for byte with optional fields at their defaults (nil)" do
      record = described_class.new(request_digest: "blake3:req",
                                   head_before: nil,
                                   head_after: "blake3:after")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"salvaged","request_digest":"blake3:req","head_before":null,' \
        '"head_after":"blake3:after"}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        request_digest: "blake3:req",
        head_before: "blake3:before",
        head_after: "blake3:after"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing request_digest, naming it" do
      given = {
        request_digest: "blake3:req",
        head_before: "blake3:before",
        head_after: "blake3:after"
      }
      expect { described_class.new(**given.except(:request_digest)) }.to raise_error(ArgumentError, /request_digest/)
    end
  end
end
