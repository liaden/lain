# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::EgressRefused do
  it "journals byte for byte, with and without a turn" do
    expect(JSON.generate(described_class.new(host: "api.example.com", count: 2, turn: 3).to_journal))
      .to eq('{"type":"egress_refused","host":"api.example.com","count":2,"turn":3}')
    expect(JSON.generate(described_class.new(host: "api.example.com", count: 1, turn: nil).to_journal))
      .to eq('{"type":"egress_refused","host":"api.example.com","count":1,"turn":null}')
  end

  it "shares the bytes of the host between 2 equal records and is shareable" do
    one = described_class.new(host: +"api.example.com", count: 1, turn: nil)
    other = described_class.new(host: +"api.example.com", count: 1, turn: nil)

    expect(one.host).to equal(other.host)
    expect(one).to be_deeply_frozen
  end

  it "counts in Integers, refusing text that is no number" do
    expect(described_class.new(host: "h", count: "2", turn: "3")).to have_attributes(count: 2, turn: 3)
    expect { described_class.new(host: "h", count: "many", turn: nil) }.to raise_error(ArgumentError)
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { described_class.new(host: "h", count: 1, turn: nil, extra: 1) }.to raise_error(ArgumentError, /extra/)
  end

  describe Lain::Telemetry::EgressRefused::Flagged do
    it "journals byte for byte under its own discriminator" do
      expect(JSON.generate(described_class.new(host: "api.example.com", regions: 1, values: 2).to_journal))
        .to eq('{"type":"egress_flagged","host":"api.example.com","regions":1,"values":2}')
    end

    it "shares the bytes of the host between 2 equal records and is shareable" do
      one = described_class.new(host: +"api.example.com", regions: 1, values: 2)
      other = described_class.new(host: +"api.example.com", regions: 1, values: 2)

      expect(one.host).to equal(other.host)
      expect(one).to be_deeply_frozen
    end

    it "refuses text that is no number, and an unknown keyword, as an ArgumentError" do
      expect { described_class.new(host: "h", regions: "x", values: 1) }.to raise_error(ArgumentError)
      expect { described_class.new(host: "h", regions: 1, values: 1, extra: 1) }
        .to raise_error(ArgumentError, /extra/)
    end
  end
end
