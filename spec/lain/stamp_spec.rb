# frozen_string_literal: true

RSpec.describe Lain::Stamp do
  describe ".iso8601" do
    it "returns a frozen Time for a good stamp" do
      time = described_class.iso8601("2026-10-27T10:11:12Z")

      expect(time).to eq(Time.utc(2026, 10, 27, 10, 11, 12)).and be_frozen
    end

    it "answers nil for a torn stamp" do
      expect(described_class.iso8601("2026-10-2")).to be_nil
    end

    it "answers nil for a non-String" do
      expect([nil, 5, %w[a]].map { described_class.iso8601(_1) }).to all(be_nil)
    end
  end
end
