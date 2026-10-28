# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ProviderRetry do
  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(attempt: 2,
                                   will_retry_in: 1.5,
                                   status: 429,
                                   reason: "Net::ReadTimeout",
                                   path: "/api/chat")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"provider_retry","attempt":2,"will_retry_in":1.5,"status":429,' \
        '"reason":"Net::ReadTimeout","path":"/api/chat"}'
      )
    end

    it "journals byte for byte with optional fields at their defaults (nil)" do
      record = described_class.new(attempt: 1)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"provider_retry","attempt":1,"will_retry_in":null,"status":null,"reason":null,' \
        '"path":null}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        attempt: 2,
        will_retry_in: 1.5,
        status: 429,
        reason: "Net::ReadTimeout",
        path: "/api/chat"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing attempt, naming it" do
      given = {
        attempt: 2,
        will_retry_in: 1.5,
        status: 429,
        reason: "Net::ReadTimeout",
        path: "/api/chat"
      }
      expect { described_class.new(**given.except(:attempt)) }.to raise_error(ArgumentError, /attempt/)
    end

    it "refuses an unknown keyword with ArgumentError" do
      expect { described_class.new(attempt: 1, bogus: 1) }.to raise_error(ArgumentError, /bogus/)
    end
  end
end
