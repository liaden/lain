# frozen_string_literal: true

require_relative "../../lib/ledger"
require_relative "../../lib/report"

RSpec.describe Report do
  it "renders the ledger's total (intentionally failing, and ordered after Ledger#total)" do
    expect(described_class.new(Ledger.new([2, 3])).to_s).to eq("total: 5")
  end

  it "counts the entries in its header (intentionally failing)" do
    expect(described_class.new(Ledger.new([2, 3])).header).to eq("entries: 2")
  end
end
