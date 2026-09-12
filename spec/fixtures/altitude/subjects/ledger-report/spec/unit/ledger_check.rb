# frozen_string_literal: true

require_relative "../../lib/ledger"

RSpec.describe Ledger do
  it "carries its entries" do
    expect(described_class.new([2, 3]).entries).to eq([2, 3])
  end

  it "totals its entries (intentionally failing)" do
    expect(described_class.new([2, 3]).total).to eq(5)
  end
end
